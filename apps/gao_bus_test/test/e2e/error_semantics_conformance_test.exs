defmodule GaoBusTest.E2E.ErrorSemanticsConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.{ExDBusClient, GLibFixture}
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]

  @e2e_009 %{
    e2e_id: "E2E-009",
    gate: :release,
    group: :errors,
    backends: @backends,
    actors: [:ex_dbus, :glib_fixture]
  }
  @tag Map.to_list(@e2e_009)
  @tag skip: ScenarioCase.skip_reason(@e2e_009)
  test "E2E-009 GLib AlwaysFail propagates exact error", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = GLibFixture.start(context)
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)

        {:ok, oracle} =
          conn
          |> ExDBusClient.call(
            GLibFixture.bus_name(),
            GLibFixture.object_path(),
            GLibFixture.interface(),
            "AlwaysFail",
            signature: "s",
            body: ["trigger_failure"]
          )
          |> Oracle.from_ex_dbus()

        assert %GaoBusTest.E2E.Result.Oracle{
                 kind: :dbus_error,
                 error_name: "org.freedesktop.DBus.Error.Failed"
               } = oracle
      after
        ExDBusClient.stop(context)
        GLibFixture.stop(context)
      end
    end)
  end
end
