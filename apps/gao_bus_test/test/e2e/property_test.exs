defmodule GaoBusTest.E2E.PropertyTest do
  @moduledoc """
  E2E scenarios 11-14: Properties (known-gap tests).

  The package does not implement D-Bus Properties. These tests verify
  that property operations don't crash the Elixir service.
  """
  use ExUnit.Case, async: false

  alias GaoBusTest.E2EHarness
  alias GaoBusTest.E2ETestService
  alias ExDBus.{Connection, Message, Proxy}

  @moduletag :e2e
  @moduletag group: :properties
  @moduletag timeout: 120_000

  setup_all do
    unless E2EHarness.tools_available?() do
      raise "Required tools (dbus-daemon, busctl, gdbus) not found"
    end

    {:ok, state} = E2EHarness.start_bus()
    {:ok, state} = E2EHarness.start_fixture(state)
    {:ok, state} = E2EHarness.connect_elixir(state)

    {:ok, _} = E2ETestService.start(state.bus_address)

    on_exit(fn ->
      E2ETestService.stop()
      E2EHarness.cleanup(state)
    end)

    {:ok, state: state}
  end

  # --- Scenario 11: busctl reads Elixir property (known gap) ---
  @tag gate: :known_gap
  @tag direction: :external_to_elixir
  test "#11 busctl reads Elixir property — predictable error, no crash", %{state: state} do
    {output, _code} =
      E2EHarness.busctl(state, [
        "get-property",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        E2ETestService.interface(),
        "SomeProperty"
      ])

    # Should get an error but NOT crash the service
    assert output =~ "Error" or output =~ "error" or output =~ "not implemented" or
             output =~ "UnknownInterface" or output =~ "No such"

    # Verify service is still alive by calling Echo
    {echo_output, echo_code} =
      E2EHarness.busctl(state, [
        "call",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        E2ETestService.interface(),
        "Echo",
        "s",
        "still_alive"
      ])

    assert echo_code == 0, "Service crashed after property read: #{echo_output}"
  end

  # --- Scenario 12: gdbus sets Elixir property (known gap) ---
  @tag gate: :known_gap
  @tag direction: :external_to_elixir
  test "#12 gdbus sets Elixir property — predictable error, no crash", %{state: state} do
    {output, _code} =
      E2EHarness.gdbus(state, [
        "call",
        "--dest=#{E2ETestService.bus_name()}",
        "--object-path=#{E2ETestService.object_path()}",
        "--method=org.freedesktop.DBus.Properties.Set",
        E2ETestService.interface(),
        "SomeProperty",
        "<'test_value'>"
      ])

    # Error expected, service should not crash
    assert output =~ "Error" or output =~ "error" or output =~ "not implemented" or
             output =~ "UnknownInterface"

    # Verify still alive
    {echo_output, echo_code} =
      E2EHarness.gdbus(state, [
        "call",
        "--dest=#{E2ETestService.bus_name()}",
        "--object-path=#{E2ETestService.object_path()}",
        "--method=#{E2ETestService.interface()}.Echo",
        "still_alive_after_set"
      ])

    assert echo_code == 0, "Service crashed after property set: #{echo_output}"
  end

  # --- Scenario 13: Elixir reads fixture property (known gap) ---
  @tag gate: :known_gap
  @tag direction: :elixir_to_external
  test "#13 Elixir reads fixture property — predictable result", %{state: state} do
    proxy =
      Proxy.new(
        state.elixir_conn,
        E2EHarness.fixture_bus_name(),
        E2EHarness.fixture_object_path()
      )

    # The fixture does support properties, so this might succeed
    # Either way, the Elixir client should not crash
    result = Proxy.get_property(proxy, E2EHarness.fixture_interface(), "CurrentValue")

    case result do
      {:ok, {_sig, value}} ->
        assert is_binary(value)

      {:error, _reason} ->
        # Known gap: acceptable error
        :ok
    end
  end

  # --- Scenario 14: PropertiesChanged not emitted by Elixir service ---
  @tag gate: :known_gap
  @tag direction: :external_to_elixir
  test "#14 PropertiesChanged signal not emitted by Elixir service", %{state: state} do
    # Create a dedicated connection owned by this test process
    {:ok, sig_conn} =
      Connection.start_link(
        address: state.bus_address,
        auth_mod: ExDBus.Auth.External,
        owner: self()
      )

    receive do
      {:ex_dbus, {:connected, _}} -> :ok
    after
      5_000 -> raise "timeout"
    end

    hello =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _} = Connection.call(sig_conn, hello, 5_000)

    # Subscribe to PropertiesChanged signals
    add_match =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: [
          "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'"
        ]
      )

    {:ok, _} = Connection.call(sig_conn, add_match, 5_000)

    # Try to trigger a property change (which should fail/be unsupported)
    {_output, _code} =
      E2EHarness.busctl(state, [
        "call",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        "org.freedesktop.DBus.Properties",
        "Set",
        "ssv",
        E2ETestService.interface(),
        "SomeProperty",
        "s",
        "new_value"
      ])

    # Should NOT receive PropertiesChanged
    received =
      receive do
        {:ex_dbus, {:message, %{type: :signal, member: "PropertiesChanged"}}} ->
          true
      after
        1_000 -> false
      end

    Connection.disconnect(sig_conn)

    refute received, "Should not receive PropertiesChanged from Elixir service"
  end
end
