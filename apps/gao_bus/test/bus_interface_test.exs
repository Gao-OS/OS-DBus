defmodule GaoBus.BusInterfaceTest do
  use ExUnit.Case, async: false

  alias ExDBus.Message
  alias GaoBus.BusInterface

  setup do
    Application.stop(:gao_bus)
    Process.sleep(50)

    # Start the minimum services BusInterface needs
    {:ok, registry} = GaoBus.NameRegistry.start_link()
    {:ok, match_rules} = GaoBus.MatchRules.start_link()

    # Ensure peer counter is initialized
    GaoBus.Peer.ensure_counter()

    on_exit(fn ->
      for pid <- [registry, match_rules] do
        if Process.alive?(pid), do: GenServer.stop(pid)
      end
    end)

    # Router state (BusInterface uses this directly)
    state = %{peers: %{}, next_serial: 1}
    %{state: state}
  end

  # A fake peer that responds to Peer GenServer calls
  defp start_fake_peer(opts \\ []) do
    unique_name = Keyword.get(opts, :unique_name, nil)

    {:ok, pid} =
      Agent.start_link(fn -> %{unique_name: unique_name} end)

    # Override get_unique_name and assign_unique_name via a wrapper GenServer
    wrapper =
      spawn_link(fn ->
        fake_peer_loop(pid)
      end)

    wrapper
  end

  defp fake_peer_loop(agent) do
    receive do
      {:"$gen_call", from, :get_unique_name} ->
        name = Agent.get(agent, & &1.unique_name)
        GenServer.reply(from, name)
        fake_peer_loop(agent)

      {:"$gen_call", from, :assign_unique_name} ->
        name = Agent.get(agent, & &1.unique_name)

        if name do
          GenServer.reply(from, name)
        else
          # Generate a new name
          GaoBus.Peer.ensure_counter()
          ref = :persistent_term.get(:gao_bus_peer_counter)
          n = :atomics.add_get(ref, 1, 1)
          new_name = ":1.#{n}"
          Agent.update(agent, fn s -> %{s | unique_name: new_name} end)
          GenServer.reply(from, new_name)
        end

        fake_peer_loop(agent)

      {:"$gen_call", from, :get_credentials} ->
        GenServer.reply(from, %{uid: 1000})
        fake_peer_loop(agent)

      _other ->
        fake_peer_loop(agent)
    end
  end

  defp bus_method_call(member, opts \\ []) do
    signature = Keyword.get(opts, :signature, nil)
    body = Keyword.get(opts, :body, [])
    interface = Keyword.get(opts, :interface, "org.freedesktop.DBus")

    %Message{
      type: :method_call,
      serial: 1,
      path: "/org/freedesktop/DBus",
      destination: "org.freedesktop.DBus",
      interface: interface,
      member: member,
      sender: ":1.99",
      signature: signature,
      body: body
    }
  end

  describe "Hello" do
    test "assigns unique name on first call", %{state: state} do
      peer = start_fake_peer()
      msg = bus_method_call("Hello")

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      [name] = reply.body
      assert String.starts_with?(name, ":1.")
    end

    test "returns error on second Hello", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.50")
      msg = bus_method_call("Hello")

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :error
      assert reply.error_name == "org.freedesktop.DBus.Error.Failed"
    end
  end

  describe "RequestName" do
    test "grants ownership", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")
      GaoBus.NameRegistry.register_unique(":1.10", peer)

      msg = bus_method_call("RequestName", signature: "su", body: ["com.test.Svc", 0])
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      # primary owner
      assert reply.body == [1]
    end
  end

  describe "ReleaseName" do
    test "releases owned name", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")
      GaoBus.NameRegistry.register_unique(":1.10", peer)
      GaoBus.NameRegistry.request_name("com.test.Svc", 0, peer, ":1.10")

      msg = bus_method_call("ReleaseName", signature: "s", body: ["com.test.Svc"])
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      # released
      assert reply.body == [1]
    end

    test "releasing non-existent name returns 2", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("ReleaseName", signature: "s", body: ["com.test.NoSuch"])
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      # non-existent
      assert reply.body == [2]
    end
  end

  describe "GetNameOwner" do
    test "returns owner of well-known name", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")
      GaoBus.NameRegistry.register_unique(":1.10", peer)
      GaoBus.NameRegistry.request_name("com.test.Svc", 0, peer, ":1.10")

      msg = bus_method_call("GetNameOwner", signature: "s", body: ["com.test.Svc"])
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      assert reply.body == [":1.10"]
    end

    test "returns error for unknown name", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("GetNameOwner", signature: "s", body: ["com.test.Unknown"])
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :error
      assert reply.error_name == "org.freedesktop.DBus.Error.NameHasNoOwner"
    end
  end

  describe "ListNames" do
    test "includes org.freedesktop.DBus", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("ListNames")
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      [names] = reply.body
      assert "org.freedesktop.DBus" in names
    end

    test "includes registered unique and well-known names", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")
      GaoBus.NameRegistry.register_unique(":1.10", peer)
      GaoBus.NameRegistry.request_name("com.test.Svc", 0, peer, ":1.10")

      msg = bus_method_call("ListNames")
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      [names] = reply.body
      assert ":1.10" in names
      assert "com.test.Svc" in names
    end
  end

  describe "ListActivatableNames" do
    test "returns empty list", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("ListActivatableNames")
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      assert reply.body == [[]]
    end
  end

  describe "NameHasOwner" do
    test "true for org.freedesktop.DBus", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("NameHasOwner", signature: "s", body: ["org.freedesktop.DBus"])
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      assert reply.body == [true]
    end

    test "false for unknown name", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("NameHasOwner", signature: "s", body: ["com.test.Unknown"])
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      assert reply.body == [false]
    end
  end

  describe "GetId" do
    test "returns bus instance ID", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("GetId")
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      [id] = reply.body
      assert is_binary(id)
      assert byte_size(id) > 0
    end
  end

  describe "AddMatch / RemoveMatch" do
    test "AddMatch succeeds for valid rule", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg =
        bus_method_call("AddMatch",
          signature: "s",
          body: ["type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'"]
        )

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
    end

    test "RemoveMatch succeeds after AddMatch", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")
      rule = "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'"

      # Add first
      add_msg = bus_method_call("AddMatch", signature: "s", body: [rule])
      {_, state} = BusInterface.handle_message(add_msg, peer, state)

      # Remove
      rem_msg = bus_method_call("RemoveMatch", signature: "s", body: [rule])
      {reply, _state} = BusInterface.handle_message(rem_msg, peer, state)

      assert reply.type == :method_return
    end

    test "RemoveMatch fails for non-existent rule", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg =
        bus_method_call("RemoveMatch",
          signature: "s",
          body: ["type='signal',member='NeverAdded'"]
        )

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :error
    end
  end

  describe "Introspect" do
    test "returns XML with bus interface", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg =
        bus_method_call("Introspect",
          interface: "org.freedesktop.DBus.Introspectable"
        )

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      [xml] = reply.body
      assert String.contains?(xml, "org.freedesktop.DBus")
      assert String.contains?(xml, "<method name=\"Hello\">")
      assert String.contains?(xml, "<method name=\"RequestName\">")
      assert String.contains?(xml, "<signal name=\"NameOwnerChanged\">")
    end
  end

  describe "Properties" do
    test "Get Features returns empty array", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg =
        bus_method_call("Get",
          interface: "org.freedesktop.DBus.Properties",
          signature: "ss",
          body: ["org.freedesktop.DBus", "Features"]
        )

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      assert [{"as", []}] = reply.body
    end

    test "Get Interfaces returns interface list", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg =
        bus_method_call("Get",
          interface: "org.freedesktop.DBus.Properties",
          signature: "ss",
          body: ["org.freedesktop.DBus", "Interfaces"]
        )

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      [{"as", interfaces}] = reply.body
      assert "org.freedesktop.DBus" in interfaces
      assert "org.freedesktop.DBus.Introspectable" in interfaces
    end

    test "Get unknown property returns error", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg =
        bus_method_call("Get",
          interface: "org.freedesktop.DBus.Properties",
          signature: "ss",
          body: ["org.freedesktop.DBus", "NoSuchProp"]
        )

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :error
      assert reply.error_name == "org.freedesktop.DBus.Error.UnknownProperty"
    end

    test "GetAll returns Features and Interfaces", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg =
        bus_method_call("GetAll",
          interface: "org.freedesktop.DBus.Properties",
          signature: "s",
          body: ["org.freedesktop.DBus"]
        )

      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :method_return
      [props] = reply.body
      keys = Enum.map(props, &elem(&1, 0))
      assert "Features" in keys
      assert "Interfaces" in keys
    end
  end

  describe "unknown method" do
    test "returns UnknownMethod error", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("NonExistentMethod")
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      assert reply.type == :error
      assert reply.error_name == "org.freedesktop.DBus.Error.UnknownMethod"
    end
  end

  describe "non-method_call messages" do
    test "returns nil for signal messages", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = %Message{
        type: :signal,
        serial: 1,
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        member: "NameOwnerChanged",
        sender: ":1.10"
      }

      assert {nil, ^state} = BusInterface.handle_message(msg, peer, state)
    end
  end

  describe "reply serial tracking" do
    test "state.next_serial increments across calls", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg1 = bus_method_call("GetId")
      {_, state} = BusInterface.handle_message(msg1, peer, state)
      assert state.next_serial > 1

      msg2 = bus_method_call("GetId")
      {_, state2} = BusInterface.handle_message(msg2, peer, state)
      assert state2.next_serial > state.next_serial
    end

    test "reply destination matches sender", %{state: state} do
      peer = start_fake_peer(unique_name: ":1.10")

      msg = bus_method_call("GetId")
      {reply, _state} = BusInterface.handle_message(msg, peer, state)

      # matches sender from bus_method_call
      assert reply.destination == ":1.99"
      assert reply.sender == "org.freedesktop.DBus"
    end
  end
end
