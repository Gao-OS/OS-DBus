defmodule GaoBusTest.E2E.MethodRoutingConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.{ElixirService, ExDBusClient, GDBus}
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]

  @e2e_007 %{
    e2e_id: "E2E-007",
    gate: :release,
    group: :methods,
    backends: @backends,
    actors: [:gdbus, :elixir_service]
  }
  @tag Map.to_list(@e2e_007)
  @tag skip: ScenarioCase.skip_reason(@e2e_007)
  test "E2E-007 gdbus calls Elixir service Add", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ElixirService.start(context)

      try do
        {result, _context} =
          GDBus.run(context, [
            "call",
            "--dest=#{ElixirService.bus_name()}",
            "--object-path=#{ElixirService.object_path()}",
            "--method=#{ElixirService.interface()}.Add",
            "2",
            "3"
          ])

        {:ok, oracle} = Oracle.from_gdbus(result)

        assert result.exit_status == 0
        assert %GaoBusTest.E2E.Result.Oracle{kind: :method_return, body: [5]} = oracle
      after
        ElixirService.stop(context)
      end
    end)
  end

  @e2e_008 %{
    e2e_id: "E2E-008",
    gate: :release,
    group: :errors,
    backends: @backends,
    actors: [:ex_dbus, :elixir_service]
  }
  @tag Map.to_list(@e2e_008)
  @tag skip: ScenarioCase.skip_reason(@e2e_008)
  test "E2E-008 unknown method returns D-Bus error", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ElixirService.start(context)
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)

        {:ok, oracle} =
          conn
          |> ExDBusClient.call(
            ElixirService.bus_name(),
            ElixirService.object_path(),
            ElixirService.interface(),
            "NoSuchMethod"
          )
          |> Oracle.from_ex_dbus()

        assert %GaoBusTest.E2E.Result.Oracle{
                 kind: :dbus_error,
                 error_name: "org.freedesktop.DBus.Error.UnknownMethod"
               } = oracle
      after
        ExDBusClient.stop(context)
        ElixirService.stop(context)
      end
    end)
  end
end
