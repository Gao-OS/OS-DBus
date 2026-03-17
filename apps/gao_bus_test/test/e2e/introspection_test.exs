defmodule GaoBusTest.E2E.IntrospectionTest do
  @moduledoc """
  E2E scenarios 15-17: Introspection in both directions.
  """
  use ExUnit.Case, async: false

  alias GaoBusTest.E2EHarness
  alias GaoBusTest.E2ETestService
  alias ExDBus.{Proxy, Introspection}

  @moduletag :e2e
  @moduletag group: :introspection
  @moduletag timeout: 120_000

  setup_all do
    {:ok, state} = E2EHarness.start_bus()
    {:ok, state} = E2EHarness.start_fixture(state)
    {:ok, state} = E2EHarness.connect_elixir(state)

    # Start Elixir test service (manages its own connection)
    {:ok, _} = E2ETestService.start(state.bus_address)
    Process.sleep(200)

    on_exit(fn ->
      E2ETestService.stop()
      E2EHarness.cleanup(state)
    end)

    {:ok, state: state}
  end

  # --- Scenario 15: busctl introspect Elixir service ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#15 busctl introspect Elixir service — valid XML with methods", %{state: state} do
    {output, code} =
      E2EHarness.busctl(state, [
        "introspect",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        "--no-pager"
      ])

    assert code == 0, "busctl introspect failed (exit #{code}): #{output}"
    assert output =~ "Echo"
    assert output =~ "Add"
    assert output =~ "EmitSignal"
  end

  # --- Scenario 16: gdbus introspect Elixir service ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#16 gdbus introspect Elixir service — valid XML consistent with busctl", %{state: state} do
    {output, code} =
      E2EHarness.gdbus(state, [
        "introspect",
        "--dest=#{E2ETestService.bus_name()}",
        "--object-path=#{E2ETestService.object_path()}"
      ])

    assert code == 0, "gdbus introspect failed (exit #{code}): #{output}"
    assert output =~ "Echo"
    assert output =~ "Add"
    assert output =~ "EmitSignal"
  end

  # --- Scenario 17: Elixir introspects fixture ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#17 Elixir introspects fixture — parsed structs match expected", %{state: state} do
    proxy =
      Proxy.new(
        state.elixir_conn,
        "com.test.ExternalFixture",
        "/com/test/ExternalFixture"
      )

    {:ok, xml} = Proxy.introspect(proxy)

    assert is_binary(xml)
    assert xml =~ "com.test.ExternalFixture"

    # Parse the XML
    {:ok, _path, interfaces, _children} = Introspection.from_xml(xml)

    # Find the fixture interface
    fixture_iface =
      Enum.find(interfaces, fn iface -> iface.name == "com.test.ExternalFixture" end)

    assert fixture_iface != nil, "Fixture interface not found in introspection"

    method_names = Enum.map(fixture_iface.methods, & &1.name)
    assert "Echo" in method_names
    assert "TypeRoundTrip" in method_names
    assert "AlwaysFail" in method_names
    assert "SlowEcho" in method_names
    assert "EmitTestSignal" in method_names

    signal_names = Enum.map(fixture_iface.signals, & &1.name)
    assert "TestSignal" in signal_names

    # Check Echo args
    echo = Enum.find(fixture_iface.methods, &(&1.name == "Echo"))
    in_args = Enum.filter(echo.args, &(&1.direction == :in))
    out_args = Enum.filter(echo.args, &(&1.direction == :out))
    assert length(in_args) == 1
    assert length(out_args) == 1
    assert hd(in_args).type == "s"
    assert hd(out_args).type == "s"
  end
end
