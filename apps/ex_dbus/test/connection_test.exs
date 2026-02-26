defmodule ExDBus.ConnectionTest do
  use ExUnit.Case, async: true

  alias ExDBus.Connection
  alias ExDBus.Message

  # A mock transport that simulates D-Bus auth and wire protocol
  defmodule MockTransport do
    @behaviour ExDBus.Transport.Behaviour

    defstruct [:pid, :socket]

    @impl true
    def connect(_address, _opts \\ []) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Connect client side
      {:ok, client} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 5_000)
      {:ok, server} = :gen_tcp.accept(listen, 5_000)
      :gen_tcp.close(listen)

      # Return client socket, stash server socket in process dict
      Process.put(:mock_server_socket, server)

      {:ok, %__MODULE__{socket: client, pid: self()}}
    end

    @impl true
    def send(%__MODULE__{socket: socket}, data) do
      :gen_tcp.send(socket, data)
    end

    @impl true
    def recv(%__MODULE__{socket: socket}, length, timeout \\ 5_000) do
      :gen_tcp.recv(socket, length, timeout)
    end

    @impl true
    def close(%__MODULE__{socket: socket}) do
      :gen_tcp.close(socket)
    end

    @impl true
    def set_active(%__MODULE__{socket: socket}, mode) do
      :inet.setopts(socket, active: mode)
    end

    @impl true
    def socket(%__MODULE__{socket: socket}), do: socket
  end

  # A mock auth that immediately succeeds
  defmodule MockAuth do
    @behaviour ExDBus.Auth.Mechanism

    defstruct [:state]

    @impl true
    def init(_opts \\ []) do
      %__MODULE__{state: :init}
    end

    @impl true
    def initial_command(state) do
      {:send, "AUTH MOCK", %{state | state: :waiting}}
    end

    @impl true
    def handle_line("OK " <> guid, state) do
      {:ok, String.trim(guid), %{state | state: :done}}
    end

    def handle_line("REJECTED" <> _, _state) do
      {:error, :rejected}
    end
  end

  describe "start_link/1" do
    test "starts and attempts connection" do
      # Start a server that handles the auth protocol
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Start a helper process to handle the server side
      test_pid = self()

      server_task = Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)

        # Read null byte
        {:ok, <<0>>} = :gen_tcp.recv(sock, 1, 5_000)

        # Read AUTH command
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        send(test_pid, {:auth_received, data})

        # Send OK response
        :gen_tcp.send(sock, "OK test_guid_123\r\n")

        # Read BEGIN
        {:ok, begin_data} = :gen_tcp.recv(sock, 0, 5_000)
        send(test_pid, {:begin_received, begin_data})

        # Keep socket open
        Process.sleep(1000)
        :gen_tcp.close(sock)
        :gen_tcp.close(listen)
      end)

      {:ok, conn} = Connection.start_link(
        address: "tcp:host=localhost,port=#{port}",
        auth_mod: MockAuth,
        owner: self()
      )

      # Should receive auth command
      assert_receive {:auth_received, auth_data}, 5_000
      assert auth_data =~ "AUTH MOCK"

      # Should receive BEGIN
      assert_receive {:begin_received, begin_data}, 5_000
      assert begin_data =~ "BEGIN"

      # Should receive connected notification
      assert_receive {:ex_dbus, {:connected, "test_guid_123"}}, 5_000

      # State should be :connected
      assert Connection.get_state(conn) == :connected
      assert Connection.get_guid(conn) == "test_guid_123"

      # Clean up
      Connection.disconnect(conn)
      Task.await(server_task, 5_000)
    end
  end

  describe "get_state/1" do
    test "returns current state" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      server_task = Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        {:ok, <<0>>} = :gen_tcp.recv(sock, 1, 5_000)
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.send(sock, "OK guid\r\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
        Process.sleep(1000)
        :gen_tcp.close(sock)
        :gen_tcp.close(listen)
      end)

      {:ok, conn} = Connection.start_link(
        address: "tcp:host=localhost,port=#{port}",
        auth_mod: MockAuth,
        owner: self()
      )

      assert_receive {:ex_dbus, {:connected, _}}, 5_000
      assert Connection.get_state(conn) == :connected

      Connection.disconnect(conn)
      assert Connection.get_state(conn) == :disconnected

      Task.await(server_task, 5_000)
    end
  end

  describe "call/3" do
    test "returns error when not connected" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Don't accept — connection will fail or timeout
      server_task = Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        # Don't send OK — leave in authenticating state
        Process.sleep(2000)
        :gen_tcp.close(sock)
        :gen_tcp.close(listen)
      end)

      {:ok, conn} = Connection.start_link(
        address: "tcp:host=localhost,port=#{port}",
        auth_mod: MockAuth,
        owner: self()
      )

      # Give it a moment but don't wait for auth to complete
      Process.sleep(100)

      msg = Message.method_call("/", "org.test.Iface", "Hello")
      assert {:error, {:not_connected, _}} = Connection.call(conn, msg, 1_000)

      Connection.disconnect(conn)
      Task.await(server_task, 5_000)
    end

    test "sends message and receives reply" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      server_task = Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)

        # Auth handshake
        {:ok, <<0>>} = :gen_tcp.recv(sock, 1, 5_000)
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.send(sock, "OK guid123\r\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)

        # Now in binary mode — receive the method_call
        {:ok, msg_data} = :gen_tcp.recv(sock, 0, 5_000)

        # Decode it
        {:ok, call_msg, _rest} = Message.decode_message(msg_data)

        # Send a method_return
        reply = Message.method_return(call_msg.serial, serial: 1, signature: "s", body: ["world"])
        reply_data = Message.encode_message(reply)
        :gen_tcp.send(sock, reply_data)

        Process.sleep(500)
        :gen_tcp.close(sock)
        :gen_tcp.close(listen)
      end)

      {:ok, conn} = Connection.start_link(
        address: "tcp:host=localhost,port=#{port}",
        auth_mod: MockAuth,
        owner: self()
      )

      assert_receive {:ex_dbus, {:connected, _}}, 5_000

      msg = Message.method_call("/test", "org.test.Iface", "Hello",
        signature: "s", body: ["hello"])

      {:ok, reply} = Connection.call(conn, msg, 5_000)
      assert reply.type == :method_return
      assert reply.body == ["world"]

      Connection.disconnect(conn)
      Task.await(server_task, 5_000)
    end
  end

  describe "cast/2" do
    test "sends signal without waiting" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      test_pid = self()

      server_task = Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)

        # Auth handshake
        {:ok, <<0>>} = :gen_tcp.recv(sock, 1, 5_000)
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.send(sock, "OK guid\r\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)

        # Receive the signal
        {:ok, msg_data} = :gen_tcp.recv(sock, 0, 5_000)
        {:ok, signal_msg, _} = Message.decode_message(msg_data)
        send(test_pid, {:received_signal, signal_msg})

        Process.sleep(500)
        :gen_tcp.close(sock)
        :gen_tcp.close(listen)
      end)

      {:ok, conn} = Connection.start_link(
        address: "tcp:host=localhost,port=#{port}",
        auth_mod: MockAuth,
        owner: self()
      )

      assert_receive {:ex_dbus, {:connected, _}}, 5_000

      signal = Message.signal("/org/test", "org.test.Iface", "SomethingHappened")
      Connection.cast(conn, signal)

      assert_receive {:received_signal, received}, 5_000
      assert received.type == :signal
      assert received.member == "SomethingHappened"

      Connection.disconnect(conn)
      Task.await(server_task, 5_000)
    end
  end

  describe "incoming signals" do
    test "dispatches to owner" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      server_task = Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)

        # Auth handshake
        {:ok, <<0>>} = :gen_tcp.recv(sock, 1, 5_000)
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.send(sock, "OK guid\r\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)

        # Send a signal from server to client
        signal = Message.signal("/org/bus", "org.freedesktop.DBus", "NameAcquired",
          serial: 1, signature: "s", body: [":1.1"])
        :gen_tcp.send(sock, Message.encode_message(signal))

        Process.sleep(500)
        :gen_tcp.close(sock)
        :gen_tcp.close(listen)
      end)

      {:ok, conn} = Connection.start_link(
        address: "tcp:host=localhost,port=#{port}",
        auth_mod: MockAuth,
        owner: self()
      )

      assert_receive {:ex_dbus, {:connected, _}}, 5_000

      # Should receive the signal from the server
      assert_receive {:ex_dbus, {:message, signal}}, 5_000
      assert signal.type == :signal
      assert signal.interface == "org.freedesktop.DBus"
      assert signal.member == "NameAcquired"
      assert signal.body == [":1.1"]

      Connection.disconnect(conn)
      Task.await(server_task, 5_000)
    end
  end

  describe "serial assignment" do
    test "auto-assigns incrementing serials" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      test_pid = self()

      server_task = Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)

        # Auth handshake
        {:ok, <<0>>} = :gen_tcp.recv(sock, 1, 5_000)
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.send(sock, "OK guid\r\n")
        {:ok, _} = :gen_tcp.recv(sock, 0, 5_000)

        # Receive signals — may arrive in one or two TCP reads
        recv_messages(sock, test_pid, 2, <<>>)

        Process.sleep(500)
        :gen_tcp.close(sock)
        :gen_tcp.close(listen)
      end)

      {:ok, conn} = Connection.start_link(
        address: "tcp:host=localhost,port=#{port}",
        auth_mod: MockAuth,
        owner: self()
      )

      assert_receive {:ex_dbus, {:connected, _}}, 5_000

      s1 = Message.signal("/a", "org.a", "A")
      s2 = Message.signal("/b", "org.b", "B")
      Connection.cast(conn, s1)
      Connection.cast(conn, s2)

      assert_receive {:serial, serial1}, 5_000
      assert_receive {:serial, serial2}, 5_000
      assert serial2 == serial1 + 1

      Connection.disconnect(conn)
      Task.await(server_task, 5_000)
    end
  end

  # Helper to receive multiple D-Bus messages that may arrive coalesced in TCP
  defp recv_messages(_sock, _pid, 0, _buffer), do: :ok

  defp recv_messages(sock, pid, remaining, buffer) do
    # Try to decode from existing buffer first
    case try_decode(buffer) do
      {:ok, msg, rest} ->
        send(pid, {:serial, msg.serial})
        recv_messages(sock, pid, remaining - 1, rest)

      :need_more ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        recv_messages(sock, pid, remaining, buffer <> data)
    end
  end

  defp try_decode(<<>>) do
    :need_more
  end

  defp try_decode(buffer) when byte_size(buffer) < 16 do
    :need_more
  end

  defp try_decode(buffer) do
    case Message.decode_message(buffer) do
      {:ok, msg, rest} -> {:ok, msg, rest}
      {:error, :insufficient_data} -> :need_more
      {:error, _} -> :need_more
    end
  end
end
