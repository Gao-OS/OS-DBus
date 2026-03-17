defmodule GaoBusTest.E2E.ConcurrencyTest do
  @moduledoc """
  E2E scenarios 26-27: Concurrent method calls.
  """
  use ExUnit.Case, async: false

  alias GaoBusTest.E2EHarness
  alias GaoBusTest.E2ETestService
  alias ExDBus.Proxy

  @moduletag :e2e
  @moduletag group: :concurrency
  @moduletag timeout: 120_000

  setup_all do
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

  # --- Scenario 26: Concurrent method calls from busctl ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#26 Concurrent busctl calls all return correct results", %{state: state} do
    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          payload = "concurrent_#{i}"

          {output, code} =
            E2EHarness.busctl(state, [
              "call",
              E2ETestService.bus_name(),
              E2ETestService.object_path(),
              E2ETestService.interface(),
              "Echo",
              "s",
              payload
            ])

          {i, code, output, payload}
        end)
      end

    results = Task.await_many(tasks, 30_000)

    for {i, code, output, payload} <- results do
      assert code == 0, "Concurrent call #{i} failed: #{output}"
      assert output =~ payload, "Call #{i} returned wrong result: #{output}"
    end
  end

  # --- Scenario 27: Concurrent Elixir calls to fixture ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#27 Concurrent Elixir calls to fixture correctly demuxed", %{state: state} do
    proxy =
      Proxy.new(
        state.elixir_conn,
        "com.test.ExternalFixture",
        "/com/test/ExternalFixture"
      )

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          payload = "elixir_concurrent_#{i}"

          result =
            Proxy.call(proxy, "com.test.ExternalFixture", "Echo",
              signature: "s",
              body: [payload]
            )

          {i, payload, result}
        end)
      end

    results = Task.await_many(tasks, 30_000)

    for {i, payload, result} <- results do
      assert {:ok, reply} = result, "Concurrent Elixir call #{i} failed: #{inspect(result)}"

      assert reply.body == [payload],
             "Call #{i} demux error: expected #{payload}, got #{inspect(reply.body)}"
    end
  end
end
