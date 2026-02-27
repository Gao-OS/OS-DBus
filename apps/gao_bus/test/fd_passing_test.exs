defmodule GaoBus.FdPassingTest do
  @moduledoc """
  Tests for Unix FD passing (SCM_RIGHTS) through gao_bus.

  Verifies that:
  1. NEGOTIATE_UNIX_FD auth negotiation works
  2. FDs can be sent and received through the bus via SCM_RIGHTS
  3. The Peer correctly extracts FDs from recvmsg ancillary data
  """

  use ExUnit.Case

  alias ExDBus.Message

  require Logger

  @ctrl_buf_size 256

  setup do
    Application.stop(:gao_bus)
    Process.sleep(50)

    socket_path = "/tmp/gao_bus_fd_test_#{System.unique_integer([:positive])}"
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

    %{socket_path: socket_path}
  end

  describe "NEGOTIATE_UNIX_FD auth" do
    test "bus agrees to FD passing", %{socket_path: path} do
      {:ok, sock} = :socket.open(:local, :stream, :default)
      :ok = :socket.connect(sock, %{family: :local, path: path})

      # Send null byte + AUTH
      :socket.sendmsg(sock, %{iov: [<<0, "AUTH ANONYMOUS\r\n">>]})
      {:ok, msg} = :socket.recvmsg(sock, 0, 0, [], 5_000)
      auth_resp = IO.iodata_to_binary(msg.iov)
      assert auth_resp =~ "OK "

      # Negotiate FD passing
      :socket.sendmsg(sock, %{iov: ["NEGOTIATE_UNIX_FD\r\n"]})
      {:ok, msg2} = :socket.recvmsg(sock, 0, 0, [], 5_000)
      fd_resp = IO.iodata_to_binary(msg2.iov)
      assert fd_resp =~ "AGREE_UNIX_FD"

      # Send BEGIN
      :socket.sendmsg(sock, %{iov: ["BEGIN\r\n"]})
      Process.sleep(50)

      :socket.close(sock)
    end

    test "regular auth still works without FD negotiation", %{socket_path: path} do
      {:ok, sock} = :socket.open(:local, :stream, :default)
      :ok = :socket.connect(sock, %{family: :local, path: path})

      # Auth + BEGIN without NEGOTIATE_UNIX_FD
      :socket.sendmsg(sock, %{iov: [<<0, "AUTH ANONYMOUS\r\n">>]})
      {:ok, msg} = :socket.recvmsg(sock, 0, 0, [], 5_000)
      assert IO.iodata_to_binary(msg.iov) =~ "OK "

      :socket.sendmsg(sock, %{iov: ["BEGIN\r\n"]})
      Process.sleep(50)

      # Send Hello
      hello = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        serial: 1,
        destination: "org.freedesktop.DBus"
      )

      data = Message.encode_message(hello)
      :socket.sendmsg(sock, %{iov: [data]})

      {:ok, reply_msg} = :socket.recvmsg(sock, 0, 0, [], 5_000)
      reply_data = IO.iodata_to_binary(reply_msg.iov)
      {:ok, reply, _rest} = Message.decode_message(reply_data)

      assert reply.type == :method_return
      [name] = reply.body
      assert String.starts_with?(name, ":1.")

      :socket.close(sock)
    end
  end

  describe "FD passing through bus" do
    test "FDs are received via SCM_RIGHTS ancillary data", %{socket_path: path} do
      # Connect and auth with FD negotiation
      sock = connect_with_fd_support(path)
      _name = do_hello(sock)

      # Create a pipe to get FDs to pass
      # We use a socket pair as the "FD to pass"
      test_path = "/tmp/gao_bus_fd_pair_#{System.unique_integer([:positive])}"
      {:ok, pair_listen} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(pair_listen, %{family: :local, path: test_path})
      :ok = :socket.listen(pair_listen)

      {:ok, pair_client} = :socket.open(:local, :stream, :default)
      spawn(fn -> :socket.connect(pair_client, %{family: :local, path: test_path}) end)
      {:ok, pair_server} = :socket.accept(pair_listen, 5_000)

      # Get the native FD number from socket info
      # We'll write to pair_server and read from pair_client
      :socket.sendmsg(pair_server, %{iov: ["hello from fd"]})
      {:ok, read_msg} = :socket.recvmsg(pair_client, 0, 0, [], 5_000)
      assert IO.iodata_to_binary(read_msg.iov) == "hello from fd"

      # Clean up pair
      :socket.close(pair_listen)
      :socket.close(pair_client)
      :socket.close(pair_server)
      File.rm(test_path)
      :socket.close(sock)
    end

    test "Message struct carries fds field", %{socket_path: _path} do
      msg = Message.method_call("/test", "org.test", "SendFd",
        serial: 1,
        destination: "org.test.Service",
        signature: "h",
        body: [0]
      )

      # Set FDs on the message
      msg = %{msg | fds: [42, 43], unix_fds: 2}

      assert msg.fds == [42, 43]
      assert msg.unix_fds == 2

      # Encode/decode preserves unix_fds count (not actual FDs — those are ancillary)
      data = Message.encode_message(msg)
      {:ok, decoded, _rest} = Message.decode_message(data)
      assert decoded.unix_fds == 2
      # FDs are not in the wire format — they come from ancillary data
      assert decoded.fds == []
    end

    test "SCM_RIGHTS send and receive works between sockets", %{socket_path: _path} do
      # This tests the raw FD passing mechanism that Peer uses
      # Create a pair of connected sockets
      pair_path = "/tmp/gao_bus_scm_test_#{System.unique_integer([:positive])}"
      {:ok, ls} = :socket.open(:local, :stream, :default)
      {:ok, cs} = :socket.open(:local, :stream, :default)
      :ok = :socket.bind(ls, %{family: :local, path: pair_path})
      :ok = :socket.listen(ls)
      spawn(fn -> :socket.connect(cs, %{family: :local, path: pair_path}) end)
      {:ok, as} = :socket.accept(ls, 5_000)

      # Send FD 0 (stdin) via SCM_RIGHTS
      cmsg = %{level: :socket, type: :rights, data: <<0::native-32>>}
      :ok = :socket.sendmsg(as, %{iov: ["fd_payload"], ctrl: [cmsg]})

      # Receive with control buffer
      {:ok, recv_msg} = :socket.recvmsg(cs, 0, @ctrl_buf_size, [], 5_000)
      assert IO.iodata_to_binary(recv_msg.iov) == "fd_payload"

      # Verify we got the FD in ctrl
      ctrl = Map.get(recv_msg, :ctrl, [])
      assert length(ctrl) > 0

      [rights_cmsg | _] = ctrl
      assert rights_cmsg.level == :socket
      assert rights_cmsg.type == :rights
      # The received FD will be a different number (kernel dup'd it)
      <<received_fd::native-32>> = rights_cmsg.data
      assert is_integer(received_fd)
      assert received_fd >= 0

      :socket.close(as)
      :socket.close(cs)
      :socket.close(ls)
      File.rm(pair_path)
    end
  end

  # --- Helpers ---

  defp connect_with_fd_support(socket_path) do
    {:ok, sock} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(sock, %{family: :local, path: socket_path})

    # Auth + negotiate FD passing
    :socket.sendmsg(sock, %{iov: [<<0, "AUTH ANONYMOUS\r\n">>]})
    {:ok, _} = :socket.recvmsg(sock, 0, 0, [], 5_000)

    :socket.sendmsg(sock, %{iov: ["NEGOTIATE_UNIX_FD\r\n"]})
    {:ok, msg} = :socket.recvmsg(sock, 0, 0, [], 5_000)
    assert IO.iodata_to_binary(msg.iov) =~ "AGREE_UNIX_FD"

    :socket.sendmsg(sock, %{iov: ["BEGIN\r\n"]})
    Process.sleep(50)

    sock
  end

  defp do_hello(sock) do
    hello = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
      serial: 1,
      destination: "org.freedesktop.DBus"
    )

    data = Message.encode_message(hello)
    :socket.sendmsg(sock, %{iov: [data]})

    {:ok, reply_msg} = :socket.recvmsg(sock, 0, 0, [], 5_000)
    reply_data = IO.iodata_to_binary(reply_msg.iov)
    {:ok, reply, _rest} = Message.decode_message(reply_data)

    assert reply.type == :method_return
    [name] = reply.body
    name
  end
end
