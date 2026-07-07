defmodule GaoBusTest.E2E.Command do
  @moduledoc """
  Unified external command runner for E2E actors.
  """

  alias GaoBusTest.E2E.Result.Command, as: CommandResult

  @default_timeout 5_000
  @collector_key {__MODULE__, :collector}

  def run(command, args \\ [], opts \\ []) when is_binary(command) and is_list(args) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    env = Keyword.get(opts, :env, [])
    cwd = Keyword.get(opts, :cwd)
    started = System.monotonic_time(:millisecond)

    command_result =
      case executable(command) do
        nil ->
          result(command, args, env, cwd, started,
            stderr: "executable not found: #{command}",
            exit_status: 127
          )

        executable ->
          task =
            Task.async(fn ->
              cmd_opts =
                [stderr_to_stdout: true, env: env]
                |> maybe_put_cwd(cwd)

              System.cmd(executable, args, cmd_opts)
            end)

          case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
            {:ok, {stdout, status}} ->
              result(executable, args, env, cwd, started, stdout: stdout, exit_status: status)

            nil ->
              result(executable, args, env, cwd, started,
                stderr: "command timed out after #{timeout}ms",
                exit_status: nil,
                timed_out?: true
              )
          end
      end

    record(command_result)
    command_result
  end

  def start_collector do
    Process.put(@collector_key, [])
    :ok
  end

  def collected do
    Process.get(@collector_key, [])
    |> Enum.reverse()
  end

  def stop_collector do
    Process.delete(@collector_key)
    :ok
  end

  defp executable(path) do
    cond do
      Path.type(path) == :absolute and File.exists?(path) -> path
      String.contains?(path, "/") and File.exists?(path) -> path
      true -> System.find_executable(path)
    end
  end

  defp maybe_put_cwd(opts, nil), do: opts
  defp maybe_put_cwd(opts, cwd), do: Keyword.put(opts, :cd, cwd)

  defp result(command, args, env, cwd, started, attrs) do
    %CommandResult{
      command: command,
      args: args,
      env: env,
      cwd: cwd,
      stdout: Keyword.get(attrs, :stdout, ""),
      stderr: Keyword.get(attrs, :stderr, ""),
      exit_status: Keyword.get(attrs, :exit_status),
      timed_out?: Keyword.get(attrs, :timed_out?, false),
      duration_ms: System.monotonic_time(:millisecond) - started
    }
  end

  defp record(%CommandResult{} = result) do
    case Process.get(@collector_key) do
      nil -> :ok
      commands -> Process.put(@collector_key, [result | commands])
    end
  end
end
