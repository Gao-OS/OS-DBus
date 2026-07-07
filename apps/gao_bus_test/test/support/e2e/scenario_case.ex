defmodule GaoBusTest.E2E.ScenarioCase do
  @moduledoc """
  Helpers for backend/gate selected E2E conformance scenarios.
  """

  alias GaoBusTest.E2E.Backend.{GaoBus, ReferenceDBusDaemon}
  alias GaoBusTest.E2E.{Command, Context, Diagnostics}

  def selected_backends do
    case System.get_env("E2E_BACKEND", "reference") do
      "reference" ->
        [:reference]

      "gao_bus" ->
        [:gao_bus]

      "both" ->
        [:reference, :gao_bus]

      other ->
        raise ArgumentError,
              "invalid E2E_BACKEND=#{inspect(other)}, expected reference | gao_bus | both"
    end
  end

  def selected_gate do
    case System.get_env("E2E_GATE", "all") do
      "smoke" ->
        :smoke

      "release" ->
        :release

      "compat" ->
        :compat

      "stress" ->
        :stress

      "all" ->
        :all

      other ->
        raise ArgumentError,
              "invalid E2E_GATE=#{inspect(other)}, expected smoke | release | compat | stress | all"
    end
  end

  def backend_mod(:reference), do: ReferenceDBusDaemon
  def backend_mod(:gao_bus), do: GaoBus

  def prepare_backend_availability! do
    for backend_name <- [:reference, :gao_bus] do
      :persistent_term.put(availability_key(backend_name), probe_backend(backend_name))
    end

    :ok
  end

  def skip_reason(tags) when is_map(tags) do
    validate_known_gap!(tags)

    cond do
      gate_skipped?(Map.fetch!(tags, :gate)) ->
        "E2E_GATE=#{System.get_env("E2E_GATE", "all")} excludes #{Map.fetch!(tags, :gate)}"

      selected_backend_names(tags) == [] ->
        "E2E_BACKEND=#{System.get_env("E2E_BACKEND", "reference")} excludes #{inspect(Map.fetch!(tags, :backends))}"

      runnable_backend_names(tags) == [] ->
        known_gap_skip_reason(tags)

      Enum.all?(runnable_backend_names(tags), &backend_unavailable?/1) ->
        runnable_backend_names(tags)
        |> Enum.map(&backend_unavailable_reason/1)
        |> Enum.join("; ")

      requires_fixture?(tags) and not GaoBusTest.E2E.Actor.GLibFixture.available?() ->
        GaoBusTest.E2E.Actor.GLibFixture.missing_reason()

      requires_busctl?(tags) and not GaoBusTest.E2E.Actor.Busctl.available?() ->
        GaoBusTest.E2E.Actor.Busctl.missing_reason()

      requires_gdbus?(tags) and not GaoBusTest.E2E.Actor.GDBus.available?() ->
        GaoBusTest.E2E.Actor.GDBus.missing_reason()

      true ->
        nil
    end
  end

  def run_scenario(tags, fun) when is_map(tags) and is_function(fun, 1) do
    validate_known_gap!(tags)

    tags
    |> runnable_backend_names()
    |> Enum.each(fn backend_name ->
      mod = backend_mod(backend_name)
      scenario_id = Map.fetch!(tags, :e2e_id)

      case mod.start(scenario_id: scenario_id) do
        {:ok, backend_state} ->
          context =
            Context.new(
              scenario_id: scenario_id,
              backend_name: backend_name,
              backend_mod: mod,
              backend_state: backend_state,
              metadata: Map.take(tags, [:gate, :group, :actors])
            )

          Command.start_collector()

          try do
            fun.(context)
            context = %{context | commands: Command.collected()}
            Diagnostics.maybe_write(context, :ok)
          rescue
            exception ->
              context = %{context | commands: Command.collected()}
              Diagnostics.maybe_write(context, exception)
              reraise exception, __STACKTRACE__
          after
            Command.stop_collector()
            Context.stop_backend(context)
          end

        {:error, reason} ->
          raise "E2E backend #{backend_name} failed to start for #{scenario_id}: #{inspect(reason)}"
      end
    end)
  end

  defp gate_skipped?(gate) do
    selected_gate() != :all and gate_rank(gate) > gate_rank(selected_gate())
  end

  defp gate_rank(:smoke), do: 1
  defp gate_rank(:release), do: 2
  defp gate_rank(:compat), do: 3
  defp gate_rank(:stress), do: 4
  defp gate_rank(_), do: 999

  defp selected_backend_names(tags) do
    allowed = Map.fetch!(tags, :backends)
    Enum.filter(selected_backends(), &(&1 in allowed))
  end

  defp runnable_backend_names(tags) do
    known_gap = Map.get(tags, :known_gap, [])
    Enum.reject(selected_backend_names(tags), &(&1 in known_gap))
  end

  defp known_gap_skip_reason(tags) do
    tags
    |> selected_backend_names()
    |> Enum.filter(&(&1 in Map.get(tags, :known_gap, [])))
    |> case do
      [backend] -> "known gap on #{backend} (see docs/e2e-matrix.md)"
      backends -> "known gap on #{Enum.join(backends, ", ")} (see docs/e2e-matrix.md)"
    end
  end

  defp validate_known_gap!(tags) do
    known_gap = Map.get(tags, :known_gap, [])

    cond do
      :reference in known_gap ->
        raise ArgumentError, "known_gap must not include :reference"

      known_gap != [] and Map.fetch!(tags, :gate) == :smoke ->
        raise ArgumentError, "smoke scenarios must not be tagged with known_gap"

      true ->
        :ok
    end
  end

  defp backend_unavailable?(backend_name), do: backend_unavailable_reason(backend_name) != nil

  defp backend_unavailable_reason(backend_name) do
    :persistent_term.get(availability_key(backend_name), nil)
  end

  defp availability_key(backend_name), do: {__MODULE__, :backend_unavailable_reason, backend_name}

  defp probe_backend(backend_name) do
    mod = backend_mod(backend_name)

    case mod.start() do
      {:ok, state} ->
        mod.stop(state)
        nil

      {:error, {:missing_executable, executable}} ->
        "#{executable} not found on PATH"

      {:error, reason} ->
        "#{backend_name} backend unavailable: #{inspect(reason)}"
    end
  end

  defp requires_fixture?(tags), do: :glib_fixture in Map.get(tags, :actors, [])
  defp requires_busctl?(tags), do: :busctl in Map.get(tags, :actors, [])
  defp requires_gdbus?(tags), do: :gdbus in Map.get(tags, :actors, [])
end
