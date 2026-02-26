defmodule ExDBus.Transport.UnixSocketTest do
  use ExUnit.Case, async: true

  alias ExDBus.Transport.UnixSocket

  describe "parse_address/1" do
    test "parses unix:path= format" do
      assert UnixSocket.parse_address("unix:path=/var/run/dbus/system_bus_socket") ==
               "/var/run/dbus/system_bus_socket"
    end

    test "parses unix:abstract= format" do
      result = UnixSocket.parse_address("unix:abstract=/tmp/dbus-test")
      assert result == <<0>> <> "/tmp/dbus-test"
    end

    test "parses bare path" do
      assert UnixSocket.parse_address("/tmp/my_socket") == "/tmp/my_socket"
    end

    test "raises on unsupported params" do
      assert_raise ArgumentError, ~r/Unsupported unix address/, fn ->
        UnixSocket.parse_address("unix:nonce-tcp=foo")
      end
    end
  end

  describe "connect/2" do
    test "returns error for nonexistent socket" do
      assert {:error, {:connect_failed, _reason, _path}} =
               UnixSocket.connect("unix:path=/tmp/nonexistent_dbus_test_socket_#{System.unique_integer()}")
    end
  end
end
