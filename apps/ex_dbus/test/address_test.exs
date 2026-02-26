defmodule ExDBus.AddressTest do
  use ExUnit.Case, async: true

  alias ExDBus.Address

  describe "parse/1" do
    test "parses unix path address" do
      assert {:ok, [{:unix, %{"path" => "/var/run/dbus/system_bus_socket"}}]} =
               Address.parse("unix:path=/var/run/dbus/system_bus_socket")
    end

    test "parses unix abstract address" do
      assert {:ok, [{:unix, %{"abstract" => "/tmp/dbus-test"}}]} =
               Address.parse("unix:abstract=/tmp/dbus-test")
    end

    test "parses tcp address" do
      assert {:ok, [{:tcp, %{"host" => "localhost", "port" => "12345"}}]} =
               Address.parse("tcp:host=localhost,port=12345")
    end

    test "parses multiple fallback addresses" do
      addr = "unix:path=/tmp/a;tcp:host=localhost,port=1234"

      assert {:ok, [
        {:unix, %{"path" => "/tmp/a"}},
        {:tcp, %{"host" => "localhost", "port" => "1234"}}
      ]} = Address.parse(addr)
    end

    test "handles hex-escaped values" do
      # Space is %20
      assert {:ok, [{:unix, %{"path" => "/tmp/my bus"}}]} =
               Address.parse("unix:path=/tmp/my%20bus")
    end

    test "rejects invalid address" do
      assert {:error, {:invalid_address, "nocolon"}} = Address.parse("nocolon")
    end

    test "handles trailing semicolons" do
      assert {:ok, [{:unix, %{"path" => "/tmp/a"}}]} =
               Address.parse("unix:path=/tmp/a;")
    end
  end

  describe "system_bus/0" do
    test "returns default system bus path" do
      # Temporarily unset the env var
      original = System.get_env("DBUS_SYSTEM_BUS_ADDRESS")
      System.delete_env("DBUS_SYSTEM_BUS_ADDRESS")

      assert Address.system_bus() == "unix:path=/var/run/dbus/system_bus_socket"

      if original, do: System.put_env("DBUS_SYSTEM_BUS_ADDRESS", original)
    end

    test "uses env var when set" do
      original = System.get_env("DBUS_SYSTEM_BUS_ADDRESS")
      System.put_env("DBUS_SYSTEM_BUS_ADDRESS", "tcp:host=remote,port=9999")

      assert Address.system_bus() == "tcp:host=remote,port=9999"

      if original do
        System.put_env("DBUS_SYSTEM_BUS_ADDRESS", original)
      else
        System.delete_env("DBUS_SYSTEM_BUS_ADDRESS")
      end
    end
  end

  describe "transport_for/1" do
    test "unix maps to UnixSocket" do
      assert Address.transport_for({:unix, %{}}) == ExDBus.Transport.UnixSocket
    end

    test "tcp maps to TCP" do
      assert Address.transport_for({:tcp, %{}}) == ExDBus.Transport.TCP
    end

    test "unknown transport returns error" do
      assert {:error, {:unknown_transport, :launchd}} = Address.transport_for({:launchd, %{}})
    end
  end

  describe "to_connect_string/1" do
    test "converts unix address back to string" do
      result = Address.to_connect_string({:unix, %{"path" => "/tmp/bus"}})
      assert result == "unix:path=/tmp/bus"
    end

    test "converts tcp address back to string" do
      result = Address.to_connect_string({:tcp, %{"host" => "localhost", "port" => "5555"}})
      assert String.starts_with?(result, "tcp:")
      assert String.contains?(result, "host=localhost")
      assert String.contains?(result, "port=5555")
    end
  end
end
