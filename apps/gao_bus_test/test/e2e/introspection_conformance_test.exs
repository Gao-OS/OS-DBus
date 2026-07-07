defmodule GaoBusTest.E2E.IntrospectionConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.{Busctl, ElixirService}
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]

  @e2e_012 %{
    e2e_id: "E2E-012",
    gate: :compat,
    group: :introspection,
    backends: @backends,
    known_gap: [:gao_bus],
    actors: [:busctl, :elixir_service]
  }
  @tag Map.to_list(@e2e_012)
  @tag skip: ScenarioCase.skip_reason(@e2e_012)
  test "E2E-012 busctl introspects Elixir service", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ElixirService.start(context)

      try do
        {result, _context} =
          Busctl.run(context, [
            "introspect",
            ElixirService.bus_name(),
            ElixirService.object_path(),
            "--no-pager"
          ])

        {:ok, oracle} = Oracle.from_busctl(result)

        assert result.exit_status == 0
        assert Oracle.body_text_contains?(oracle, ElixirService.interface())
        assert Oracle.body_text_contains?(oracle, "Echo")
        assert Oracle.body_text_contains?(oracle, "Add")
        assert Oracle.body_text_contains?(oracle, "EmitSignal")
      after
        ElixirService.stop(context)
      end
    end)
  end
end
