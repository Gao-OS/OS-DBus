defmodule ExDBus.ProxyTest do
  use ExUnit.Case

  alias ExDBus.Proxy

  describe "new/3" do
    test "creates proxy with defaults" do
      proxy = Proxy.new(:fake_conn, "org.freedesktop.DBus", "/org/freedesktop/DBus")
      assert proxy.connection == :fake_conn
      assert proxy.destination == "org.freedesktop.DBus"
      assert proxy.path == "/org/freedesktop/DBus"
    end

    test "defaults path to /" do
      proxy = Proxy.new(:fake_conn, "com.example.Service")
      assert proxy.path == "/"
    end
  end
end
