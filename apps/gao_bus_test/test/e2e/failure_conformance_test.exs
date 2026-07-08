defmodule GaoBusTest.E2E.FailureConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.{ExDBusClient, GLibFixture}
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]
  @dbus_interface "org.freedesktop.DBus"

  @e2e_016 %{
    e2e_id: "E2E-016",
    gate: :release,
    group: :failure,
    backends: @backends,
    actors: [:ex_dbus, :glib_fixture]
  }
  @tag Map.to_list(@e2e_016)
  @tag skip: ScenarioCase.skip_reason(@e2e_016)
  test "E2E-016 service disconnect cleans owned name", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = GLibFixture.start(context)
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [fixture_owner]}} =
          ExDBusClient.get_name_owner(conn, GLibFixture.bus_name()) |> Oracle.from_ex_dbus()

        rule =
          "type='signal',interface='#{@dbus_interface}',member='NameOwnerChanged'," <>
            "arg0='#{GLibFixture.bus_name()}'"

        {:ok, _} = ExDBusClient.add_match(conn, rule)
        {:ok, context} = GLibFixture.stop(context)

        {:ok, signal} =
          ExDBusClient.await_signal_matching(
            @dbus_interface,
            "NameOwnerChanged",
            &(&1.body == [GLibFixture.bus_name(), fixture_owner, ""]),
            3_000
          )

        assert %GaoBusTest.E2E.Result.Oracle{
                 kind: :signal,
                 body: [_, ^fixture_owner, ""]
               } = Oracle.from_message(signal)
      after
        ExDBusClient.stop(context)
        GLibFixture.stop(context)
      end
    end)
  end

  @e2e_017 %{
    e2e_id: "E2E-017",
    gate: :release,
    group: :failure,
    backends: @backends,
    actors: [:ex_dbus]
  }
  @tag Map.to_list(@e2e_017)
  @tag skip: ScenarioCase.skip_reason(@e2e_017)
  test "E2E-017 client disconnect does not crash bus", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ExDBusClient.start(context, name: :client_a)

      try do
        {:ok, conn_a} = ExDBusClient.conn(context, :client_a)
        unique_a = ExDBusClient.unique_name(context, :client_a)
        :ok = ExDBusClient.abrupt_disconnect(conn_a)
        {:ok, context} = ExDBusClient.stop(context, name: :client_a)

        {:ok, context} = ExDBusClient.start(context, name: :client_b)

        try do
          {:ok, conn_b} = ExDBusClient.conn(context, :client_b)

          {:ok, %GaoBusTest.E2E.Result.Oracle{body: [names]}} =
            ExDBusClient.list_names(conn_b) |> Oracle.from_ex_dbus()

          assert "org.freedesktop.DBus" in names
          assert :ok = await_name_absent(conn_b, unique_a, 3_000)
        after
          ExDBusClient.stop(context, name: :client_b)
        end
      after
        ExDBusClient.stop(context, name: :client_a)
      end
    end)
  end

  defp await_name_absent(conn, name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_name_absent_until(conn, name, deadline)
  end

  defp await_name_absent_until(conn, name, deadline) do
    {:ok, %GaoBusTest.E2E.Result.Oracle{body: [names]}} =
      ExDBusClient.list_names(conn) |> Oracle.from_ex_dbus()

    cond do
      name not in names ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:name_still_owned, name, names}}

      true ->
        receive do
        after
          25 -> await_name_absent_until(conn, name, deadline)
        end
    end
  end
end
