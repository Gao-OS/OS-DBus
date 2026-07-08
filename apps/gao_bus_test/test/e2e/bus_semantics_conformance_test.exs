defmodule GaoBusTest.E2E.BusSemanticsConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.ExDBusClient
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]

  @e2e_018 %{
    e2e_id: "E2E-018",
    gate: :release,
    group: :routing,
    backends: @backends,
    actors: [:ex_dbus]
  }
  @tag Map.to_list(@e2e_018)
  @tag skip: ScenarioCase.skip_reason(@e2e_018)
  test "E2E-018 method call to missing destination returns error", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)

        {:ok, oracle} =
          conn
          |> ExDBusClient.call(
            "com.test.NoSuchService.N#{System.unique_integer([:positive])}",
            "/com/test/NoSuchService",
            "com.test.NoSuchService",
            "Missing"
          )
          |> Oracle.from_ex_dbus()

        assert %GaoBusTest.E2E.Result.Oracle{
                 kind: :dbus_error,
                 error_name: "org.freedesktop.DBus.Error.ServiceUnknown"
               } = oracle
      after
        ExDBusClient.stop(context)
      end
    end)
  end

  @e2e_019 %{
    e2e_id: "E2E-019",
    gate: :release,
    group: :bus,
    backends: @backends,
    actors: [:ex_dbus]
  }
  @tag Map.to_list(@e2e_019)
  @tag skip: ScenarioCase.skip_reason(@e2e_019)
  test "E2E-019 GetNameOwner works after RequestName", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)
        name = unique_bus_name("GetNameOwner")
        unique = ExDBusClient.unique_name(context)

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [1]}} =
          ExDBusClient.request_name(conn, name) |> Oracle.from_ex_dbus()

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [^unique]}} =
          ExDBusClient.get_name_owner(conn, name) |> Oracle.from_ex_dbus()

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [1]}} =
          ExDBusClient.release_name(conn, name) |> Oracle.from_ex_dbus()

        {:ok, oracle} = ExDBusClient.get_name_owner(conn, name) |> Oracle.from_ex_dbus()

        assert %GaoBusTest.E2E.Result.Oracle{
                 kind: :dbus_error,
                 error_name: "org.freedesktop.DBus.Error.NameHasNoOwner"
               } = oracle
      after
        ExDBusClient.stop(context)
      end
    end)
  end

  @e2e_020 %{
    e2e_id: "E2E-020",
    gate: :release,
    group: :bus,
    backends: @backends,
    actors: [:ex_dbus]
  }
  @tag Map.to_list(@e2e_020)
  @tag skip: ScenarioCase.skip_reason(@e2e_020)
  test "E2E-020 NameHasOwner reflects ownership", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)
        name = unique_bus_name("NameHasOwner")

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [false]}} =
          ExDBusClient.name_has_owner(conn, name) |> Oracle.from_ex_dbus()

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [1]}} =
          ExDBusClient.request_name(conn, name) |> Oracle.from_ex_dbus()

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [true]}} =
          ExDBusClient.name_has_owner(conn, name) |> Oracle.from_ex_dbus()

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [1]}} =
          ExDBusClient.release_name(conn, name) |> Oracle.from_ex_dbus()

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [false]}} =
          ExDBusClient.name_has_owner(conn, name) |> Oracle.from_ex_dbus()
      after
        ExDBusClient.stop(context)
      end
    end)
  end

  defp unique_bus_name(scenario) do
    "com.test.Conformance.#{scenario}.N#{System.unique_integer([:positive])}"
  end
end
