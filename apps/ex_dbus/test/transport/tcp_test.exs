defmodule ExDBus.Transport.TCPTest do
  use ExUnit.Case, async: true

  alias ExDBus.Transport.TCP

  describe "parse_address/1" do
    test "parses tcp address string" do
      assert TCP.parse_address("tcp:host=localhost,port=12345") == {"localhost", 12345}
    end

    test "defaults host to localhost" do
      assert TCP.parse_address("tcp:port=9999") == {"localhost", 9999}
    end

    test "defaults port to 0" do
      assert TCP.parse_address("tcp:host=example.com") == {"example.com", 0}
    end

    test "parses tuple passthrough" do
      assert TCP.parse_address({"myhost", 5555}) == {"myhost", 5555}
    end
  end

  describe "connect/2" do
    test "returns error for connection refused" do
      # Use a port that's very unlikely to be listening
      assert {:error, {:connect_failed, _reason, {"localhost", 19999}}} =
               TCP.connect("tcp:host=localhost,port=19999", timeout: 500)
    end
  end

  describe "transport lifecycle with loopback" do
    test "connect, send, recv, close with echo server" do
      # Start a simple TCP listener
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Accept in a separate process
      parent = self()

      spawn(fn ->
        {:ok, server_sock} = :gen_tcp.accept(listen, 5_000)
        {:ok, data} = :gen_tcp.recv(server_sock, 0, 5_000)
        :gen_tcp.send(server_sock, data)
        send(parent, :echo_done)
        :gen_tcp.close(server_sock)
        :gen_tcp.close(listen)
      end)

      {:ok, transport} = TCP.connect("tcp:host=localhost,port=#{port}")
      :ok = TCP.send(transport, "hello dbus")
      {:ok, data} = TCP.recv(transport, 0, 5_000)
      assert data == "hello dbus"
      assert_receive :echo_done, 5_000
      :ok = TCP.close(transport)
    end
  end
end
