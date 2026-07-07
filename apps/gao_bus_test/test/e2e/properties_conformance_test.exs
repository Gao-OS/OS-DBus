defmodule GaoBusTest.E2E.PropertiesConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.{GDBus, GLibFixture}
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]

  @e2e_013 %{
    e2e_id: "E2E-013",
    gate: :compat,
    group: :properties,
    backends: @backends,
    actors: [:gdbus, :glib_fixture]
  }
  @tag Map.to_list(@e2e_013)
  @tag skip: ScenarioCase.skip_reason(@e2e_013)
  test "E2E-013 gdbus Get property from GLib fixture", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = GLibFixture.start(context)

      try do
        {result, _context} = get_current_value(context)
        {:ok, oracle} = Oracle.from_gdbus(result)

        assert result.exit_status == 0
        assert %GaoBusTest.E2E.Result.Oracle{kind: :method_return, body: ["initial"]} = oracle
      after
        GLibFixture.stop(context)
      end
    end)
  end

  @e2e_014 %{
    e2e_id: "E2E-014",
    gate: :compat,
    group: :properties,
    backends: @backends,
    actors: [:gdbus, :glib_fixture]
  }
  @tag Map.to_list(@e2e_014)
  @tag skip: ScenarioCase.skip_reason(@e2e_014)
  test "E2E-014 gdbus Set property on GLib fixture", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = GLibFixture.start(context)

      try do
        value = "property_N#{System.unique_integer([:positive])}"

        {set_result, _context} =
          GDBus.run(context, [
            "call",
            "--dest=#{GLibFixture.bus_name()}",
            "--object-path=#{GLibFixture.object_path()}",
            "--method=org.freedesktop.DBus.Properties.Set",
            GLibFixture.interface(),
            "CurrentValue",
            "<'#{value}'>"
          ])

        assert set_result.exit_status == 0

        {get_result, _context} = get_current_value(context)
        {:ok, oracle} = Oracle.from_gdbus(get_result)

        assert get_result.exit_status == 0
        assert %GaoBusTest.E2E.Result.Oracle{kind: :method_return, body: [^value]} = oracle
      after
        GLibFixture.stop(context)
      end
    end)
  end

  defp get_current_value(context) do
    GDBus.run(context, [
      "call",
      "--dest=#{GLibFixture.bus_name()}",
      "--object-path=#{GLibFixture.object_path()}",
      "--method=org.freedesktop.DBus.Properties.Get",
      GLibFixture.interface(),
      "CurrentValue"
    ])
  end
end
