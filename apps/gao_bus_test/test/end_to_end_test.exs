defmodule GaoBusTest.EndToEndTest do
  @moduledoc """
  End-to-end integration tests.

  Starts gao_bus, connects gao_config's BusClient through it,
  then uses a separate ex_dbus client to call Config1 methods
  through the bus — exercising the full message path.
  """
  use ExUnit.Case

  alias ExDBus.{Connection, Message, Proxy}

  @socket_path "/tmp/gao_bus_e2e_test_#{System.unique_integer([:positive])}"

  setup_all do
    # Stop apps if running
    Application.stop(:gao_config)
    Application.stop(:gao_bus)
    Process.sleep(100)

    # Start gao_bus with custom socket
    Application.put_env(:gao_bus, :socket_path, @socket_path)
    {:ok, _} = Application.ensure_all_started(:gao_bus)
    Process.sleep(200)

    # Start gao_config with bus client enabled
    Application.put_env(:gao_config, :connect_to_bus, true)
    Application.put_env(:gao_config, :bus_address, "unix:path=#{@socket_path}")
    Application.put_env(:gao_config, :store_path, "/tmp/gao_config_e2e.dat")
    {:ok, _} = Application.ensure_all_started(:gao_config)

    # Wait for BusClient to connect and register
    Process.sleep(500)

    # Connect our test client
    {:ok, conn} =
      Connection.start_link(
        address: "unix:path=#{@socket_path}",
        auth_mod: ExDBus.Auth.Anonymous,
        owner: self()
      )

    receive do
      {:ex_dbus, {:connected, _guid}} -> :ok
    after
      2_000 -> raise "test client connection timeout"
    end

    # Hello
    hello =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _reply} = Connection.call(conn, hello, 2_000)

    on_exit(fn ->
      Connection.disconnect(conn)
      Application.stop(:gao_config)
      Application.stop(:gao_bus)
      Application.put_env(:gao_config, :connect_to_bus, false)
      File.rm(@socket_path)
      File.rm("/tmp/gao_config_e2e.dat")
    end)

    {:ok, conn: conn}
  end

  setup %{conn: conn} do
    # Clear config store before each test
    GaoConfig.ConfigStore.clear()
    {:ok, conn: conn}
  end

  describe "Config1 through the bus" do
    test "Set and Get a value", %{conn: conn} do
      config = Proxy.new(conn, "org.gaoos.Config1", "/org/gaoos/Config1")

      # Set
      {:ok, _reply} =
        Proxy.call(config, "org.gaoos.Config1", "Set",
          signature: "sss",
          body: ["network", "hostname", "gaoos-test"]
        )

      # Get
      {:ok, reply} =
        Proxy.call(config, "org.gaoos.Config1", "Get",
          signature: "ss",
          body: ["network", "hostname"]
        )

      assert reply.body == ["gaoos-test"]
    end

    test "GetVersion returns version", %{conn: conn} do
      config = Proxy.new(conn, "org.gaoos.Config1", "/org/gaoos/Config1")

      {:ok, reply} = Proxy.call(config, "org.gaoos.Config1", "GetVersion")

      assert reply.body == ["0.1.0"]
    end

    test "ListSections returns populated sections", %{conn: conn} do
      config = Proxy.new(conn, "org.gaoos.Config1", "/org/gaoos/Config1")

      # Set data in multiple sections
      Proxy.call(config, "org.gaoos.Config1", "Set",
        signature: "sss",
        body: ["audio", "volume", "80"]
      )

      Proxy.call(config, "org.gaoos.Config1", "Set",
        signature: "sss",
        body: ["display", "brightness", "50"]
      )

      {:ok, reply} = Proxy.call(config, "org.gaoos.Config1", "ListSections")
      [sections] = reply.body
      assert "audio" in sections
      assert "display" in sections
    end

    test "Delete removes a key", %{conn: conn} do
      config = Proxy.new(conn, "org.gaoos.Config1", "/org/gaoos/Config1")

      # Set then delete
      Proxy.call(config, "org.gaoos.Config1", "Set",
        signature: "sss",
        body: ["temp", "key", "val"]
      )

      {:ok, _} =
        Proxy.call(config, "org.gaoos.Config1", "Delete",
          signature: "ss",
          body: ["temp", "key"]
        )

      # Get should fail
      {:error, {:dbus_error, "org.gaoos.Config1.Error.NotFound", _}} =
        Proxy.call(config, "org.gaoos.Config1", "Get",
          signature: "ss",
          body: ["temp", "key"]
        )
    end

    test "List returns entries in section", %{conn: conn} do
      config = Proxy.new(conn, "org.gaoos.Config1", "/org/gaoos/Config1")

      Proxy.call(config, "org.gaoos.Config1", "Set",
        signature: "sss",
        body: ["myapp", "a", "1"]
      )

      Proxy.call(config, "org.gaoos.Config1", "Set",
        signature: "sss",
        body: ["myapp", "b", "2"]
      )

      {:ok, reply} =
        Proxy.call(config, "org.gaoos.Config1", "List",
          signature: "s",
          body: ["myapp"]
        )

      [pairs] = reply.body
      assert {"a", "1"} in pairs
      assert {"b", "2"} in pairs
    end

    test "Introspect returns valid XML", %{conn: conn} do
      config = Proxy.new(conn, "org.gaoos.Config1", "/org/gaoos/Config1")

      {:ok, reply} = Proxy.call(config, "org.freedesktop.DBus.Introspectable", "Introspect")
      [xml] = reply.body
      assert String.contains?(xml, "org.gaoos.Config1")
      assert String.contains?(xml, "<method name=\"Get\">")
      assert String.contains?(xml, "<method name=\"Set\">")
    end
  end

  describe "bus introspection" do
    test "bus itself is introspectable", %{conn: conn} do
      bus = Proxy.new(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus")

      {:ok, reply} = Proxy.call(bus, "org.freedesktop.DBus.Introspectable", "Introspect")
      [xml] = reply.body
      assert String.contains?(xml, "org.freedesktop.DBus")
      assert String.contains?(xml, "Hello")
      assert String.contains?(xml, "RequestName")
    end

    test "org.gaoos.Config1 is visible in ListNames", %{conn: conn} do
      bus = Proxy.new(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus")

      {:ok, reply} = Proxy.call(bus, "org.freedesktop.DBus", "ListNames")
      [names] = reply.body
      assert "org.gaoos.Config1" in names
      assert "org.freedesktop.DBus" in names
    end
  end
end
