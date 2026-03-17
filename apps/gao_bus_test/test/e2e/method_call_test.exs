defmodule GaoBusTest.E2E.MethodCallTest do
  @moduledoc """
  E2E scenarios 1-6: Method calls in both directions.
  Tests against a real dbus-daemon with external tools and C fixture.
  """
  use ExUnit.Case, async: false

  alias GaoBusTest.E2EHarness
  alias GaoBusTest.E2ETestService
  alias ExDBus.Proxy

  @moduletag :e2e
  @moduletag group: :methods
  @moduletag timeout: 120_000

  setup_all do
    unless E2EHarness.tools_available?() do
      raise "Required tools (dbus-daemon, busctl, gdbus) not found"
    end

    unless E2EHarness.fixture_available?() do
      raise "Fixture binary not found. Run: make -C apps/gao_bus_test/test/fixture"
    end

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

  # --- Scenario 1: busctl calls Elixir method ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#1 busctl calls Elixir Echo method", %{state: state} do
    {output, code} =
      E2EHarness.busctl(state, [
        "call",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        E2ETestService.interface(),
        "Echo",
        "s",
        "hello_from_busctl"
      ])

    assert code == 0, "busctl call failed (exit #{code}): #{output}"
    assert output =~ "hello_from_busctl"
  end

  # --- Scenario 2: gdbus calls Elixir method ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#2 gdbus calls Elixir Echo method", %{state: state} do
    {output, code} =
      E2EHarness.gdbus(state, [
        "call",
        "--dest=#{E2ETestService.bus_name()}",
        "--object-path=#{E2ETestService.object_path()}",
        "--method=#{E2ETestService.interface()}.Echo",
        "hello_from_gdbus"
      ])

    assert code == 0, "gdbus call failed (exit #{code}): #{output}"
    assert output =~ "hello_from_gdbus"
  end

  # --- Scenario 3: Elixir calls fixture Echo ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#3 Elixir calls fixture Echo", %{state: state} do
    proxy =
      Proxy.new(
        state.elixir_conn,
        "com.test.ExternalFixture",
        "/com/test/ExternalFixture"
      )

    {:ok, reply} =
      Proxy.call(proxy, "com.test.ExternalFixture", "Echo",
        signature: "s",
        body: ["hello_from_elixir"]
      )

    assert reply.body == ["hello_from_elixir"]
  end

  # --- Scenario 4: Type round-trip ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#4 Elixir calls fixture TypeRoundTrip for various types", %{state: state} do
    proxy =
      Proxy.new(
        state.elixir_conn,
        "com.test.ExternalFixture",
        "/com/test/ExternalFixture"
      )

    # String
    {:ok, reply} =
      Proxy.call(proxy, "com.test.ExternalFixture", "TypeRoundTrip",
        signature: "v",
        body: [{"s", "test_string"}]
      )

    [{"s", value}] = reply.body
    assert value == "test_string"

    # Integer (int32)
    {:ok, reply} =
      Proxy.call(proxy, "com.test.ExternalFixture", "TypeRoundTrip",
        signature: "v",
        body: [{"i", 42}]
      )

    [{"i", value}] = reply.body
    assert value == 42

    # Boolean
    {:ok, reply} =
      Proxy.call(proxy, "com.test.ExternalFixture", "TypeRoundTrip",
        signature: "v",
        body: [{"b", true}]
      )

    [{"b", value}] = reply.body
    assert value == true

    # Double
    {:ok, reply} =
      Proxy.call(proxy, "com.test.ExternalFixture", "TypeRoundTrip",
        signature: "v",
        body: [{"d", 3.14}]
      )

    [{"d", value}] = reply.body
    assert_in_delta value, 3.14, 0.001
  end

  # --- Scenario 5: busctl calls nonexistent method ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#5 busctl calls nonexistent method on Elixir service", %{state: state} do
    {output, code} =
      E2EHarness.busctl(state, [
        "call",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        E2ETestService.interface(),
        "NoSuchMethod"
      ])

    # Should get an error (non-zero exit or error in output)
    assert code != 0 or output =~ "UnknownMethod" or output =~ "Error",
           "Expected error for nonexistent method, got: #{output}"
  end

  # --- Scenario 6: Elixir calls fixture AlwaysFail ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#6 Elixir calls fixture AlwaysFail and receives D-Bus error", %{state: state} do
    proxy =
      Proxy.new(
        state.elixir_conn,
        "com.test.ExternalFixture",
        "/com/test/ExternalFixture"
      )

    result =
      Proxy.call(proxy, "com.test.ExternalFixture", "AlwaysFail",
        signature: "s",
        body: ["trigger_failure"]
      )

    assert {:error, {:dbus_error, error_name, _body}} = result
    assert error_name =~ "Error"
  end
end
