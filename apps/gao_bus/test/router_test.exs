defmodule GaoBus.RouterTest do
  use ExUnit.Case, async: false

  alias ExDBus.Message
  alias GaoBus.{MatchRules, NameRegistry, Router}

  setup do
    Application.stop(:gao_bus)
    Process.sleep(50)

    {:ok, nr} = NameRegistry.start_link()
    {:ok, mr} = MatchRules.start_link()
    {:ok, router} = Router.start_link()

    # Ensure peer counter is initialized for Hello handling
    GaoBus.Peer.ensure_counter()

    on_exit(fn ->
      for pid <- [router, mr, nr] do
        if Process.alive?(pid), do: GenServer.stop(pid)
      end
    end)

    :ok
  end

  # --- Fake peer helpers ---

  # A simple process that forwards all messages to the test process.
  defp start_fake_peer do
    test_pid = self()
    spawn_link(fn -> fake_peer_loop(test_pid) end)
  end

  defp fake_peer_loop(test_pid) do
    receive do
      msg ->
        send(test_pid, {:peer_received, msg})
        fake_peer_loop(test_pid)
    end
  end

  # A fake peer that also responds to GenServer calls from BusInterface
  # (needed for Hello, RequestName, etc.).
  defp start_fake_peer_with_genserver(opts \\ []) do
    unique_name = Keyword.get(opts, :unique_name, nil)

    {:ok, agent} = Agent.start_link(fn -> %{unique_name: unique_name} end)
    test_pid = self()

    pid =
      spawn_link(fn ->
        genserver_peer_loop(agent, test_pid)
      end)

    {pid, agent}
  end

  defp genserver_peer_loop(agent, test_pid) do
    receive do
      {:"$gen_call", from, :get_unique_name} ->
        name = Agent.get(agent, & &1.unique_name)
        GenServer.reply(from, name)
        genserver_peer_loop(agent, test_pid)

      {:"$gen_call", from, :assign_unique_name} ->
        name = Agent.get(agent, & &1.unique_name)

        if name do
          GenServer.reply(from, name)
        else
          GaoBus.Peer.ensure_counter()
          ref = :persistent_term.get(:gao_bus_peer_counter)
          n = :atomics.add_get(ref, 1, 1)
          new_name = ":1.#{n}"
          Agent.update(agent, fn s -> %{s | unique_name: new_name} end)
          GenServer.reply(from, new_name)
        end

        genserver_peer_loop(agent, test_pid)

      {:"$gen_call", from, :get_credentials} ->
        GenServer.reply(from, %{uid: 1000})
        genserver_peer_loop(agent, test_pid)

      msg ->
        send(test_pid, {:peer_received, msg})
        genserver_peer_loop(agent, test_pid)
    end
  end

  # --- Message helpers ---

  defp bus_method_call(member, opts) do
    sender = Keyword.get(opts, :sender, ":1.99")
    serial = Keyword.get(opts, :serial, 1)
    signature = Keyword.get(opts, :signature, nil)
    body = Keyword.get(opts, :body, [])

    %Message{
      type: :method_call,
      serial: serial,
      path: "/org/freedesktop/DBus",
      destination: "org.freedesktop.DBus",
      interface: "org.freedesktop.DBus",
      member: member,
      sender: sender,
      signature: signature,
      body: body
    }
  end

  defp method_call_to(destination, member, opts) do
    sender = Keyword.get(opts, :sender, ":1.1")
    serial = Keyword.get(opts, :serial, 1)
    signature = Keyword.get(opts, :signature, nil)
    body = Keyword.get(opts, :body, [])

    %Message{
      type: :method_call,
      serial: serial,
      path: "/some/path",
      interface: "com.example.Interface",
      member: member,
      destination: destination,
      sender: sender,
      signature: signature,
      body: body
    }
  end

  # --- Tests ---

  describe "register_peer/unregister_peer" do
    test "registered peer receives signals" do
      peer = start_fake_peer()
      Router.register_peer(peer, ":1.50")
      Process.sleep(50)

      signal =
        Message.signal("/test", "com.test.Iface", "TestSignal",
          sender: ":1.1",
          serial: 1
        )

      Router.route(signal, self())
      Process.sleep(50)

      assert_receive {:peer_received, {:send_message, msg}}
      assert msg.type == :signal
      assert msg.member == "TestSignal"
    end

    test "unregistered peer stops receiving signals" do
      peer = start_fake_peer()
      Router.register_peer(peer, ":1.50")
      Process.sleep(50)

      Router.unregister_peer(peer)
      Process.sleep(50)

      signal =
        Message.signal("/test", "com.test.Iface", "TestSignal",
          sender: ":1.1",
          serial: 1
        )

      Router.route(signal, self())
      Process.sleep(50)

      refute_receive {:peer_received, _}
    end
  end

  describe "emit_signal" do
    test "emitted signal is delivered to registered peers" do
      peer = start_fake_peer()
      Router.register_peer(peer, ":1.50")
      Process.sleep(50)

      Router.emit_signal(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        "sss",
        ["com.test.Svc", "", ":1.10"]
      )

      Process.sleep(50)

      assert_receive {:peer_received, {:send_message, msg}}
      assert msg.type == :signal
      assert msg.member == "NameOwnerChanged"
      assert msg.sender == "org.freedesktop.DBus"
      assert msg.body == ["com.test.Svc", "", ":1.10"]
    end

    test "emitted signal has auto-incremented serial" do
      peer = start_fake_peer()
      Router.register_peer(peer, ":1.50")
      Process.sleep(50)

      Router.emit_signal("/test", "com.test.I", "Sig1", nil, [])
      Router.emit_signal("/test", "com.test.I", "Sig2", nil, [])
      Process.sleep(50)

      assert_receive {:peer_received, {:send_message, msg1}}
      assert_receive {:peer_received, {:send_message, msg2}}
      assert msg2.serial > msg1.serial
    end
  end

  describe "route method_call to bus (org.freedesktop.DBus)" do
    test "Hello message returns unique name to peer" do
      {peer, _agent} = start_fake_peer_with_genserver()

      msg = bus_method_call("Hello", sender: ":1.99")
      Router.route(msg, peer)
      Process.sleep(100)

      assert_receive {:peer_received, {:send_message, reply}}
      assert reply.type == :method_return
      [name] = reply.body
      assert String.starts_with?(name, ":1.")
    end

    test "ListNames returns at least org.freedesktop.DBus" do
      {peer, _agent} = start_fake_peer_with_genserver(unique_name: ":1.10")

      msg = bus_method_call("ListNames", sender: ":1.10")
      Router.route(msg, peer)
      Process.sleep(100)

      assert_receive {:peer_received, {:send_message, reply}}
      assert reply.type == :method_return
      [names] = reply.body
      assert "org.freedesktop.DBus" in names
    end
  end

  describe "route method_call to named peer" do
    test "message is delivered to the target peer" do
      # Register sender in the NameRegistry so error replies can route back
      sender_peer = start_fake_peer()
      NameRegistry.register_unique(":1.1", sender_peer)

      # Register target peer with a well-known name
      target_peer = start_fake_peer()
      NameRegistry.register_unique(":1.10", target_peer)
      NameRegistry.request_name("com.test.Target", 0, target_peer, ":1.10")

      msg = method_call_to("com.test.Target", "DoStuff", sender: ":1.1")
      Router.route(msg, sender_peer)
      Process.sleep(50)

      assert_receive {:peer_received, {:send_message, delivered}}
      assert delivered.type == :method_call
      assert delivered.member == "DoStuff"
      assert delivered.destination == "com.test.Target"
    end

    test "message to unique name is delivered" do
      sender_peer = start_fake_peer()
      NameRegistry.register_unique(":1.1", sender_peer)

      target_peer = start_fake_peer()
      NameRegistry.register_unique(":1.20", target_peer)

      msg = method_call_to(":1.20", "Ping", sender: ":1.1")
      Router.route(msg, sender_peer)
      Process.sleep(50)

      assert_receive {:peer_received, {:send_message, delivered}}
      assert delivered.type == :method_call
      assert delivered.member == "Ping"
    end
  end

  describe "route to unknown destination" do
    test "returns ServiceUnknown error to sender" do
      # Register self() directly so the error reply comes to this process
      NameRegistry.register_unique(":1.1", self())
      Process.sleep(50)

      msg = method_call_to("com.nonexistent.Service", "Call", sender: ":1.1")
      Router.route(msg, self())
      Process.sleep(50)

      assert_receive {:send_message, error_msg}, 500
      assert error_msg.type == :error
      assert error_msg.error_name == "org.freedesktop.DBus.Error.ServiceUnknown"
    end
  end

  describe "route method_return/error" do
    test "method_return is routed back to the sender by destination" do
      caller_peer = start_fake_peer()
      NameRegistry.register_unique(":1.1", caller_peer)

      reply =
        Message.method_return(1,
          serial: 5,
          destination: ":1.1",
          sender: ":1.20",
          signature: "s",
          body: ["hello"]
        )

      Router.route(reply, self())
      Process.sleep(50)

      assert_receive {:peer_received, {:send_message, delivered}}
      assert delivered.type == :method_return
      assert delivered.body == ["hello"]
    end

    test "error is routed back to the sender by destination" do
      caller_peer = start_fake_peer()
      NameRegistry.register_unique(":1.1", caller_peer)

      error =
        Message.error("org.freedesktop.DBus.Error.Failed", 1,
          serial: 5,
          destination: ":1.1",
          sender: ":1.20",
          signature: "s",
          body: ["something broke"]
        )

      Router.route(error, self())
      Process.sleep(50)

      assert_receive {:peer_received, {:send_message, delivered}}
      assert delivered.type == :error
      assert delivered.error_name == "org.freedesktop.DBus.Error.Failed"
      assert delivered.body == ["something broke"]
    end

    test "method_return to unknown destination is silently dropped" do
      reply =
        Message.method_return(1,
          serial: 5,
          destination: ":1.999",
          sender: ":1.20"
        )

      Router.route(reply, self())
      Process.sleep(50)

      refute_receive {:peer_received, _}
    end
  end

  describe "auto-unregister on process death" do
    test "dead peer is removed from registered peers" do
      peer = start_fake_peer()
      Router.register_peer(peer, ":1.50")
      Process.sleep(50)

      # Kill the peer
      Process.unlink(peer)
      Process.exit(peer, :kill)
      Process.sleep(100)

      # Send a signal — dead peer should not receive it
      # We need a live peer to verify signals still work
      live_peer = start_fake_peer()
      Router.register_peer(live_peer, ":1.51")
      Process.sleep(50)

      signal =
        Message.signal("/test", "com.test.Iface", "Ping",
          sender: ":1.1",
          serial: 1
        )

      Router.route(signal, self())
      Process.sleep(50)

      # Only the live peer should receive it
      assert_receive {:peer_received, {:send_message, msg}}
      assert msg.member == "Ping"

      # No second message (dead peer didn't get one)
      refute_receive {:peer_received, _}
    end
  end

  describe "signal broadcasting" do
    test "signal is delivered to all registered peers" do
      peer1 = start_fake_peer()
      peer2 = start_fake_peer()
      peer3 = start_fake_peer()

      Router.register_peer(peer1, ":1.10")
      Router.register_peer(peer2, ":1.11")
      Router.register_peer(peer3, ":1.12")
      Process.sleep(50)

      signal =
        Message.signal("/test", "com.test.Iface", "Broadcast",
          sender: ":1.1",
          serial: 1
        )

      Router.route(signal, self())
      Process.sleep(50)

      # All three peers should receive the signal
      assert_receive {:peer_received, {:send_message, m1}}
      assert_receive {:peer_received, {:send_message, m2}}
      assert_receive {:peer_received, {:send_message, m3}}

      for msg <- [m1, m2, m3] do
        assert msg.type == :signal
        assert msg.member == "Broadcast"
      end
    end

    test "signal with match rules only goes to matching peers" do
      peer1 = start_fake_peer()
      peer2 = start_fake_peer()

      Router.register_peer(peer1, ":1.10")
      Router.register_peer(peer2, ":1.11")
      Process.sleep(50)

      # peer1 subscribes to a specific signal
      MatchRules.add_match(peer1, "type='signal',interface='com.test.Specific',member='Matched'")
      # peer2 subscribes to a different signal
      MatchRules.add_match(peer2, "type='signal',interface='com.test.Other',member='Other'")

      signal =
        Message.signal("/test", "com.test.Specific", "Matched",
          sender: ":1.1",
          serial: 1
        )

      Router.route(signal, self())
      Process.sleep(50)

      # peer1 matches, peer2 does not match
      assert_receive {:peer_received, {:send_message, msg}}
      assert msg.member == "Matched"

      # peer2 should not get it (it has rules, but none match)
      refute_receive {:peer_received, _}
    end
  end

  describe "route method_call with nil destination" do
    test "treats as bus message" do
      {peer, _agent} = start_fake_peer_with_genserver(unique_name: ":1.10")

      msg = %Message{
        type: :method_call,
        serial: 1,
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        member: "GetId",
        destination: nil,
        sender: ":1.10"
      }

      Router.route(msg, peer)
      Process.sleep(100)

      assert_receive {:peer_received, {:send_message, reply}}
      assert reply.type == :method_return
      [id] = reply.body
      assert is_binary(id)
      assert byte_size(id) > 0
    end
  end
end
