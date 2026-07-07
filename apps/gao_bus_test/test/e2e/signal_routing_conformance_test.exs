defmodule GaoBusTest.E2E.SignalRoutingConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.{ExDBusClient, GLibFixture}
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]
  @signal_rule "type='signal',interface='#{GLibFixture.interface()}',member='TestSignal'"

  @e2e_010 %{
    e2e_id: "E2E-010",
    gate: :release,
    group: :signals,
    backends: @backends,
    actors: [:ex_dbus, :glib_fixture]
  }
  @tag Map.to_list(@e2e_010)
  @tag skip: ScenarioCase.skip_reason(@e2e_010)
  test "E2E-010 AddMatch receives matching signal", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = GLibFixture.start(context)
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)
        payload = "signal_match_N#{System.unique_integer([:positive])}"

        {:ok, _} = ExDBusClient.add_match(conn, @signal_rule)

        {:ok, _} =
          ExDBusClient.call(
            conn,
            GLibFixture.bus_name(),
            GLibFixture.object_path(),
            GLibFixture.interface(),
            "EmitTestSignal",
            signature: "s",
            body: [payload]
          )

        {:ok, signal} =
          ExDBusClient.await_signal(GLibFixture.interface(), "TestSignal", [payload], 2_000)

        oracle = Oracle.from_message(signal)

        assert %GaoBusTest.E2E.Result.Oracle{
                 kind: :signal,
                 interface: "com.test.ExternalFixture",
                 member: "TestSignal",
                 body: [^payload]
               } = oracle
      after
        ExDBusClient.stop(context)
        GLibFixture.stop(context)
      end
    end)
  end

  @e2e_011 %{
    e2e_id: "E2E-011",
    gate: :release,
    group: :signals,
    backends: @backends,
    actors: [:ex_dbus, :glib_fixture]
  }
  @tag Map.to_list(@e2e_011)
  @tag skip: ScenarioCase.skip_reason(@e2e_011)
  test "E2E-011 unmatched signal is not delivered", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = GLibFixture.start(context)
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)
        unmatched_rule = "type='signal',interface='com.test.DoesNotMatch',member='TestSignal'"
        negative_payload = "signal_unmatched_N#{System.unique_integer([:positive])}"
        positive_payload = "signal_positive_N#{System.unique_integer([:positive])}"

        {:ok, _} = ExDBusClient.add_match(conn, unmatched_rule)

        {:ok, _} =
          ExDBusClient.call(
            conn,
            GLibFixture.bus_name(),
            GLibFixture.object_path(),
            GLibFixture.interface(),
            "EmitTestSignal",
            signature: "s",
            body: [negative_payload]
          )

        assert :ok = ExDBusClient.refute_signal(GLibFixture.interface(), "TestSignal", 300)

        {:ok, _} = ExDBusClient.add_match(conn, @signal_rule)

        {:ok, _} =
          ExDBusClient.call(
            conn,
            GLibFixture.bus_name(),
            GLibFixture.object_path(),
            GLibFixture.interface(),
            "EmitTestSignal",
            signature: "s",
            body: [positive_payload]
          )

        {:ok, signal} =
          ExDBusClient.await_signal(
            GLibFixture.interface(),
            "TestSignal",
            [positive_payload],
            2_000
          )

        assert %GaoBusTest.E2E.Result.Oracle{kind: :signal, body: [^positive_payload]} =
                 Oracle.from_message(signal)
      after
        ExDBusClient.stop(context)
        GLibFixture.stop(context)
      end
    end)
  end
end
