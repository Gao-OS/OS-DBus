defmodule GaoBusTest.E2E.SmokeConformanceTest do
  use ExUnit.Case, async: false

  alias GaoBusTest.E2E.Actor.{Busctl, ElixirService, ExDBusClient, GLibFixture}
  alias GaoBusTest.E2E.{Oracle, ScenarioCase}

  @moduletag :e2e
  @moduletag timeout: 120_000

  @backends [:reference, :gao_bus]

  @e2e_001 %{
    e2e_id: "E2E-001",
    gate: :smoke,
    group: :hello,
    backends: @backends,
    actors: [:ex_dbus]
  }
  @tag Map.to_list(@e2e_001)
  @tag skip: ScenarioCase.skip_reason(@e2e_001)
  test "E2E-001 Hello returns a unique name", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ExDBusClient.start(context)

      try do
        assert ":" <> _ = ExDBusClient.unique_name(context)
        assert String.starts_with?(ExDBusClient.unique_name(context), ":1.")
      after
        ExDBusClient.stop(context)
      end
    end)
  end

  @e2e_002 %{
    e2e_id: "E2E-002",
    gate: :smoke,
    group: :bus,
    backends: @backends,
    actors: [:ex_dbus]
  }
  @tag Map.to_list(@e2e_002)
  @tag skip: ScenarioCase.skip_reason(@e2e_002)
  test "E2E-002 ListNames includes org.freedesktop.DBus", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)
        {:ok, oracle} = ExDBusClient.list_names(conn) |> Oracle.from_ex_dbus()

        assert Oracle.method_return?(oracle)

        assert ["org.freedesktop.DBus" | _] =
                 Enum.filter(List.first(oracle.body), &(&1 == "org.freedesktop.DBus"))
      after
        ExDBusClient.stop(context)
      end
    end)
  end

  @e2e_003 %{
    e2e_id: "E2E-003",
    gate: :smoke,
    group: :names,
    backends: @backends,
    actors: [:ex_dbus]
  }
  @tag Map.to_list(@e2e_003)
  @tag skip: ScenarioCase.skip_reason(@e2e_003)
  test "E2E-003 RequestName returns primary owner", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)
        name = "com.test.Conformance.RequestName.N#{System.unique_integer([:positive])}"
        {:ok, oracle} = ExDBusClient.request_name(conn, name) |> Oracle.from_ex_dbus()

        assert %GaoBusTest.E2E.Result.Oracle{kind: :method_return, body: [1]} = oracle
      after
        ExDBusClient.stop(context)
      end
    end)
  end

  @e2e_004 %{
    e2e_id: "E2E-004",
    gate: :smoke,
    group: :names,
    backends: @backends,
    actors: [:ex_dbus]
  }
  @tag Map.to_list(@e2e_004)
  @tag skip: ScenarioCase.skip_reason(@e2e_004)
  test "E2E-004 ReleaseName removes owner", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ExDBusClient.start(context)

      try do
        {:ok, conn} = ExDBusClient.conn(context)
        name = "com.test.Conformance.ReleaseName.N#{System.unique_integer([:positive])}"

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [1]}} =
          ExDBusClient.request_name(conn, name) |> Oracle.from_ex_dbus()

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [1]}} =
          ExDBusClient.release_name(conn, name) |> Oracle.from_ex_dbus()

        {:ok, %GaoBusTest.E2E.Result.Oracle{body: [false]}} =
          ExDBusClient.name_has_owner(conn, name) |> Oracle.from_ex_dbus()
      after
        ExDBusClient.stop(context)
      end
    end)
  end

  @e2e_005 %{
    e2e_id: "E2E-005",
    gate: :release,
    group: :methods,
    backends: @backends,
    actors: [:ex_dbus, :glib_fixture]
  }
  @tag Map.to_list(@e2e_005)
  @tag skip: ScenarioCase.skip_reason(@e2e_005)
  test "E2E-005 ExDBus client calls GLib fixture Echo", tags do
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
            "Echo",
            signature: "s",
            body: ["hello_from_conformance"]
          )
          |> Oracle.from_ex_dbus()

        assert %GaoBusTest.E2E.Result.Oracle{
                 kind: :method_return,
                 body: ["hello_from_conformance"]
               } = oracle
      after
        ExDBusClient.stop(context)
        GLibFixture.stop(context)
      end
    end)
  end

  @e2e_006 %{
    e2e_id: "E2E-006",
    gate: :release,
    group: :methods,
    backends: @backends,
    actors: [:busctl, :elixir_service]
  }
  @tag Map.to_list(@e2e_006)
  @tag skip: ScenarioCase.skip_reason(@e2e_006)
  test "E2E-006 busctl calls Elixir service Echo", tags do
    ScenarioCase.run_scenario(tags, fn context ->
      {:ok, context} = ElixirService.start(context)

      try do
        {result, _context} =
          Busctl.run(context, [
            "call",
            ElixirService.bus_name(),
            ElixirService.object_path(),
            ElixirService.interface(),
            "Echo",
            "s",
            "hello_from_busctl_conformance"
          ])

        {:ok, oracle} = Oracle.from_busctl(result)

        assert result.exit_status == 0
        assert Oracle.method_return?(oracle)
        assert Oracle.contains_body?(oracle, "s \"hello_from_busctl_conformance\"")
      after
        ElixirService.stop(context)
      end
    end)
  end
end
