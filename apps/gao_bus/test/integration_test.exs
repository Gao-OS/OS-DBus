defmodule GaoBus.IntegrationTest do
  use ExUnit.Case

  alias ExDBus.{Connection, Message}

  @moduletag :integration

  setup do
    # Stop the auto-started application to avoid named process conflicts
    Application.stop(:gao_bus)
    Process.sleep(50)

    socket_path = "/tmp/gao_bus_test_#{System.unique_integer([:positive])}"
    Application.put_env(:gao_bus, :socket_path, socket_path)

    {:ok, sup} = GaoBus.Application.start(:normal, [])
    Process.sleep(100)

    on_exit(fn ->
      try do
        Supervisor.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      File.rm(socket_path)
    end)

    %{socket_path: socket_path, sup: sup}
  end

  defp connect_client(socket_path) do
    {:ok, conn} = Connection.start_link(
      address: "unix:path=#{socket_path}",
      auth_mod: ExDBus.Auth.Anonymous,
      owner: self()
    )

    assert_receive {:ex_dbus, {:connected, _guid}}, 5_000
    conn
  end

  defp call_hello(conn) do
    msg = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
      destination: "org.freedesktop.DBus")
    {:ok, reply} = Connection.call(conn, msg, 5_000)
    assert reply.type == :method_return
    [unique_name] = reply.body
    assert String.starts_with?(unique_name, ":1.")
    unique_name
  end

  describe "bus lifecycle" do
    test "start and stop bus", %{socket_path: path} do
      assert File.exists?(path)
    end

    test "client connects and authenticates", %{socket_path: path} do
      conn = connect_client(path)
      assert Connection.get_state(conn) == :connected
      Connection.disconnect(conn)
    end
  end

  describe "org.freedesktop.DBus.Hello" do
    test "assigns unique name", %{socket_path: path} do
      conn = connect_client(path)
      name = call_hello(conn)
      assert name =~ ~r/^:1\.\d+$/
      Connection.disconnect(conn)
    end

    test "two clients get different names", %{socket_path: path} do
      conn_a = connect_client(path)
      conn_b = connect_client(path)
      name_a = call_hello(conn_a)
      name_b = call_hello(conn_b)

      assert name_a != name_b

      Connection.disconnect(conn_a)
      Connection.disconnect(conn_b)
    end
  end

  describe "org.freedesktop.DBus.ListNames" do
    test "lists registered names", %{socket_path: path} do
      conn = connect_client(path)
      name = call_hello(conn)

      msg = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames",
        destination: "org.freedesktop.DBus")
      {:ok, reply} = Connection.call(conn, msg, 5_000)
      [names] = reply.body

      assert "org.freedesktop.DBus" in names
      assert name in names

      Connection.disconnect(conn)
    end
  end

  describe "org.freedesktop.DBus.RequestName / ReleaseName" do
    test "request and release a well-known name", %{socket_path: path} do
      conn = connect_client(path)
      _name = call_hello(conn)

      # RequestName
      req = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        destination: "org.freedesktop.DBus",
        signature: "su",
        body: ["com.example.Test", 0])
      {:ok, reply} = Connection.call(conn, req, 5_000)
      assert reply.body == [1]  # DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER

      # GetNameOwner
      get = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: ["com.example.Test"])
      {:ok, reply} = Connection.call(conn, get, 5_000)
      assert reply.type == :method_return

      # ReleaseName
      rel = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: ["com.example.Test"])
      {:ok, reply} = Connection.call(conn, rel, 5_000)
      assert reply.body == [1]  # DBUS_RELEASE_NAME_REPLY_RELEASED

      Connection.disconnect(conn)
    end
  end

  describe "peer-to-peer method call" do
    test "client A calls client B, gets response", %{socket_path: path} do
      conn_a = connect_client(path)
      conn_b = connect_client(path)
      _name_a = call_hello(conn_a)
      _name_b = call_hello(conn_b)

      # B registers a well-known name
      req = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        destination: "org.freedesktop.DBus",
        signature: "su",
        body: ["com.example.Service", 0])
      {:ok, _} = Connection.call(conn_b, req, 5_000)

      # A sends a method_call to B's well-known name (async so we can handle B's response)
      call_msg = Message.method_call("/com/example/Object", "com.example.Interface", "DoStuff",
        destination: "com.example.Service",
        signature: "s",
        body: ["ping"])

      # Use Task.async for A's call so test process can receive B's incoming message
      task = Task.async(fn ->
        Connection.call(conn_a, call_msg, 10_000)
      end)

      # B's connection dispatches the method_call to us (the owner)
      # Drain any signals (NameOwnerChanged etc.) until we get the method_call
      incoming = receive_method_call(5_000)
      assert incoming.member == "DoStuff"
      assert incoming.body == ["ping"]

      # Send reply from B
      reply = Message.method_return(incoming.serial,
        destination: incoming.sender,
        signature: "s",
        body: ["pong"])
      Connection.cast(conn_b, reply)

      # A should receive the reply
      {:ok, a_reply} = Task.await(task, 10_000)
      assert a_reply.type == :method_return
      assert a_reply.body == ["pong"]

      Connection.disconnect(conn_a)
      Connection.disconnect(conn_b)
    end
  end

  describe "org.freedesktop.DBus.NameHasOwner" do
    test "returns true for existing name", %{socket_path: path} do
      conn = connect_client(path)
      _name = call_hello(conn)

      msg = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: ["org.freedesktop.DBus"])
      {:ok, reply} = Connection.call(conn, msg, 5_000)
      assert reply.body == [true]

      Connection.disconnect(conn)
    end

    test "returns false for non-existent name", %{socket_path: path} do
      conn = connect_client(path)
      _name = call_hello(conn)

      msg = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: ["com.does.not.exist"])
      {:ok, reply} = Connection.call(conn, msg, 5_000)
      assert reply.body == [false]

      Connection.disconnect(conn)
    end
  end

  # Drain signals from the mailbox until we get a method_call
  defp receive_method_call(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive do
      {:ex_dbus, {:message, %Message{type: :method_call} = msg}} ->
        msg

      {:ex_dbus, {:message, %Message{type: :signal}}} ->
        remaining = max(0, deadline - System.monotonic_time(:millisecond))
        receive_method_call(remaining)
    after
      timeout ->
        flunk("Timed out waiting for method_call")
    end
  end
end
