defmodule GaoBusTest.E2E.ConcurrencyConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.{ExDBusClient, GLibFixture}
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]

  @e2e_015 %{
    e2e_id: "E2E-015",
    gate: :stress,
    group: :concurrency,
    backends: @backends,
    actors: [:ex_dbus, :glib_fixture]
  }
  @tag Map.to_list(@e2e_015)
  @tag skip: ScenarioCase.skip_reason(@e2e_015)
  test "E2E-015 concurrent calls demux correctly", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = GLibFixture.start(context)
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)
        payloads = for n <- 1..20, do: "concurrent_N#{n}_#{System.unique_integer([:positive])}"

        replies =
          payloads
          |> Task.async_stream(&echo(conn, &1), max_concurrency: 20, timeout: 10_000)
          |> Enum.map(fn {:ok, reply} -> reply end)

        assert Enum.sort(replies) == Enum.sort(payloads)
      after
        ExDBusClient.stop(context)
        GLibFixture.stop(context)
      end
    end)
  end

  defp echo(conn, payload) do
    {:ok, oracle} =
      conn
      |> ExDBusClient.call(
        GLibFixture.bus_name(),
        GLibFixture.object_path(),
        GLibFixture.interface(),
        "Echo",
        signature: "s",
        body: [payload]
      )
      |> Oracle.from_ex_dbus()

    %GaoBusTest.E2E.Result.Oracle{kind: :method_return, body: [^payload]} = oracle
    payload
  end
end
