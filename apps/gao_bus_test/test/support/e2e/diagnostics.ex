defmodule GaoBusTest.E2E.Diagnostics do
  @moduledoc """
  Writes scenario artifacts for E2E failures and retained runs.
  """

  alias GaoBusTest.E2E.Context

  def keep_artifacts?, do: System.get_env("E2E_KEEP_ARTIFACTS") == "1"

  def write(%Context{} = context, reason) do
    dir = context.artifacts_dir || default_artifact_dir(context)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "context.json"), encode(context_payload(context, reason)))
    File.write!(Path.join(dir, "backend.log"), backend_log(context))
    File.write!(Path.join(dir, "fixture.log"), fixture_log(context))
    File.write!(Path.join(dir, "commands.jsonl"), commands_jsonl(context))

    {:ok, dir}
  end

  def maybe_write(%Context{} = context, reason) do
    if keep_artifacts?() or failure?(reason), do: write(context, reason), else: :ok
  end

  def default_artifact_dir(%Context{} = context) do
    unique_id = "#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

    Path.join([
      Mix.Project.build_path(),
      "e2e_artifacts",
      context.scenario_id || "unknown",
      Atom.to_string(context.backend_name || :unknown),
      unique_id
    ])
  end

  defp context_payload(%Context{} = context, reason) do
    %{
      scenario_id: context.scenario_id,
      backend_name: context.backend_name,
      bus_address: context.bus_address,
      tmpdir: context.tmpdir,
      started_at: DateTime.to_iso8601(context.started_at),
      metadata: context.metadata,
      actors: Map.keys(context.actors),
      reason: inspect(reason)
    }
  end

  defp backend_log(%Context{backend_mod: mod, backend_state: state}) do
    state
    |> mod.diagnostics()
    |> Map.get(:log, "")
    |> to_string()
  rescue
    exception -> "backend diagnostics failed: #{Exception.message(exception)}"
  end

  defp fixture_log(%Context{actors: actors}) do
    actors
    |> Map.get(:glib_fixture, %{})
    |> Map.get(:log, "")
    |> to_string()
  end

  defp commands_jsonl(%Context{commands: commands}) do
    commands
    |> Enum.reverse()
    |> Enum.map(fn command -> encode(Map.from_struct(command)) <> "\n" end)
    |> IO.iodata_to_binary()
  end

  defp failure?(:ok), do: false
  defp failure?(nil), do: false
  defp failure?(_), do: true

  defp encode(value), do: json(value)

  defp json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> json(to_string(key)) <> ":" <> json(val) end)
    |> Enum.join(",")
    |> then(&("{" <> &1 <> "}"))
  end

  defp json(value) when is_list(value) do
    value
    |> Enum.map(&json/1)
    |> Enum.join(",")
    |> then(&("[" <> &1 <> "]"))
  end

  defp json(value) when is_atom(value), do: json(Atom.to_string(value))
  defp json(value) when is_binary(value), do: inspect(value)
  defp json(value) when is_integer(value), do: Integer.to_string(value)
  defp json(value) when is_float(value), do: Float.to_string(value)
  defp json(true), do: "true"
  defp json(false), do: "false"
  defp json(nil), do: "null"
  defp json(value), do: json(inspect(value))
end
