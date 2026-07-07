defmodule GaoBusTest.E2E.Actor.GLibFixture do
  @moduledoc """
  Actor wrapper for the C/GLib external fixture.
  """

  alias GaoBusTest.E2E.Context

  @fixture_binary Path.expand(
                    Path.join([__DIR__, "..", "..", "..", "fixture", "external_fixture"])
                  )
  @startup_timeout 10_000

  @bus_name "com.test.ExternalFixture"
  @object_path "/com/test/ExternalFixture"
  @interface "com.test.ExternalFixture"

  def bus_name, do: @bus_name
  def object_path, do: @object_path
  def interface, do: @interface
  def fixture_binary, do: @fixture_binary

  def available?, do: File.exists?(@fixture_binary)

  def missing_reason do
    "Fixture binary not found at #{@fixture_binary}. Run: make -C apps/gao_bus_test/test/fixture"
  end

  def start(%Context{} = context, _opts \\ []) do
    if available?() do
      port =
        Port.open(
          {:spawn_executable, @fixture_binary},
          [
            :binary,
            :stderr_to_stdout,
            :exit_status,
            args: ["--bus-address=#{context.bus_address}"],
            env: [{~c"DBUS_SESSION_BUS_ADDRESS", String.to_charlist(context.bus_address)}]
          ]
        )

      case wait_for_ready(port, "") do
        {:ok, log} ->
          {:os_pid, pid} = Port.info(port, :os_pid)
          actor = %{port: port, pid: pid, log: log, binary: @fixture_binary}
          {:ok, Context.put_actor(context, :glib_fixture, actor)}

        {:error, reason, log} ->
          stop_port(port, nil)
          context = put_failed_actor(context, reason, log)
          {:error, {reason, log}, context}
      end
    else
      {:error, {:skip, missing_reason()}, context}
    end
  end

  def stop(%Context{} = context) do
    case Context.get_actor(context, :glib_fixture) do
      {:ok, %{port: port, pid: pid}} -> stop_port(port, pid)
      :error -> :ok
    end

    {:ok, Context.delete_actor(context, :glib_fixture)}
  end

  defp wait_for_ready(port, acc) do
    receive do
      {^port, {:data, data}} ->
        log = acc <> data

        if String.contains?(log, "READY") do
          {:ok, log}
        else
          wait_for_ready(port, log)
        end

      {^port, {:exit_status, code}} ->
        {:error, {:fixture_exited, code}, acc}
    after
      @startup_timeout -> {:error, :fixture_ready_timeout, acc}
    end
  end

  defp put_failed_actor(%Context{} = context, reason, log) do
    actor = %{
      port: nil,
      pid: nil,
      log: log,
      binary: @fixture_binary,
      start_error: reason
    }

    Context.put_actor(context, :glib_fixture, actor)
  end

  defp stop_port(nil, _), do: :ok

  defp stop_port(port, pid) do
    if pid do
      System.cmd("kill", ["-TERM", "#{pid}"], stderr_to_stdout: true)
      Process.sleep(100)
      System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
    end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
end
