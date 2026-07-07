defmodule GaoBusTest.E2EHarness do
  @moduledoc """
  Compatibility wrapper for the backend-agnostic E2E conformance harness.
  """

  alias GaoBusTest.E2E.Actor.{Busctl, GDBus, GLibFixture}
  alias GaoBusTest.E2E.Backend.ReferenceDBusDaemon
  alias GaoBusTest.E2E.Command
  alias GaoBusTest.E2E.Context

  @tool_timeout 5_000
  @startup_timeout 10_000

  defstruct [
    :tmpdir,
    :socket_path,
    :bus_address,
    :daemon_port,
    :daemon_pid,
    :fixture_port,
    :fixture_pid,
    :elixir_conn,
    :backend_state
  ]

  def fixture_bus_name, do: GLibFixture.bus_name()
  def fixture_object_path, do: GLibFixture.object_path()
  def fixture_interface, do: GLibFixture.interface()

  @doc "Check if required external tools are available."
  def tools_available? do
    required_tools_skip_reason() == nil
  end

  def required_tools_skip_reason do
    missing =
      ["dbus-daemon", "busctl", "gdbus"]
      |> Enum.filter(&(System.find_executable(&1) == nil))

    case missing do
      [] -> nil
      tools -> "required external tools not found: #{Enum.join(tools, ", ")}"
    end
  end

  @doc "Check if the C fixture binary exists (needs `make -C test/fixture`)."
  def fixture_available?, do: GLibFixture.available?()

  @doc "Start an isolated dbus-daemon session bus."
  def start_bus do
    case ReferenceDBusDaemon.start() do
      {:ok, backend_state} ->
        {:ok, from_backend(backend_state)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Start the C fixture service on the given bus."
  def start_fixture(%__MODULE__{bus_address: addr} = state) do
    unless fixture_available?() do
      raise GLibFixture.missing_reason()
    end

    port =
      Port.open(
        {:spawn_executable, GLibFixture.fixture_binary()},
        [
          :binary,
          :stderr_to_stdout,
          :exit_status,
          args: ["--bus-address=#{addr}"],
          env: [{~c"DBUS_SESSION_BUS_ADDRESS", String.to_charlist(addr)}]
        ]
      )

    wait_for_ready(port)
    {:os_pid, fixture_pid} = Port.info(port, :os_pid)
    {:ok, %{state | fixture_port: port, fixture_pid: fixture_pid}}
  end

  @doc "Connect an Elixir client to the test bus."
  def connect_elixir(%__MODULE__{bus_address: addr} = state) do
    {:ok, conn} =
      ExDBus.Connection.start_link(
        address: addr,
        auth_mod: ExDBus.Auth.External,
        owner: self()
      )

    receive do
      {:ex_d_bus, {:connected, _guid}} -> :ok
    after
      @startup_timeout -> raise "Elixir connection to test bus timed out"
    end

    hello =
      ExDBus.Message.method_call(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _reply} = ExDBus.Connection.call(conn, hello, @tool_timeout)

    {:ok, %{state | elixir_conn: conn}}
  end

  @doc "Run busctl against the test bus."
  def busctl(%__MODULE__{} = state, args, opts \\ []) do
    context = context_from_state(state)
    {result, _context} = Busctl.run(context, args, opts)
    {result.stdout <> result.stderr, result.exit_status || 1}
  end

  @doc "Run gdbus against the test bus."
  def gdbus(%__MODULE__{} = state, args, opts \\ []) do
    context = context_from_state(state)
    {result, _context} = GDBus.run(context, args, opts)
    {result.stdout <> result.stderr, result.exit_status || 1}
  rescue
    e -> {"gdbus error: #{Exception.message(e)}", 1}
  end

  @doc "Run gdbus monitor as a background port, returns port."
  def gdbus_monitor(%__MODULE__{bus_address: addr}, match_args) do
    gdbus_path = System.find_executable("gdbus")

    Port.open(
      {:spawn_executable, gdbus_path},
      [
        :binary,
        :stderr_to_stdout,
        args: ["monitor", "--address=#{addr}"] ++ match_args
      ]
    )
  end

  @doc "Run busctl monitor as a background port, returns port."
  def busctl_monitor(%__MODULE__{bus_address: addr}, match_args \\ []) do
    busctl_path =
      System.find_executable("busctl") ||
        raise "busctl not found on PATH"

    Port.open(
      {:spawn_executable, busctl_path},
      [
        :binary,
        :stderr_to_stdout,
        args: ["--address=#{addr}", "monitor"] ++ match_args,
        env: [{~c"DBUS_SESSION_BUS_ADDRESS", String.to_charlist(addr)}]
      ]
    )
  end

  @doc "Run any command through the conformance command runner."
  def command(command, args, opts \\ []), do: Command.run(command, args, opts)

  @doc "Tear down everything."
  def cleanup(%__MODULE__{} = state) do
    if state.elixir_conn do
      try do
        ExDBus.Connection.disconnect(state.elixir_conn)
      catch
        _, _ -> :ok
      end
    end

    kill_port(state.fixture_port, state.fixture_pid)

    if state.backend_state do
      ReferenceDBusDaemon.stop(state.backend_state)
    else
      kill_port(state.daemon_port, state.daemon_pid)
      if state.tmpdir, do: File.rm_rf(state.tmpdir)
    end

    :ok
  end

  def cleanup(%{__struct__: _} = state), do: cleanup(Map.from_struct(state))

  def cleanup(state) when is_map(state) do
    state
    |> struct(__MODULE__)
    |> cleanup()
  end

  defp from_backend(%ReferenceDBusDaemon{} = backend_state) do
    %__MODULE__{
      tmpdir: backend_state.tmpdir,
      socket_path: backend_state.socket_path,
      bus_address: backend_state.bus_address,
      daemon_port: backend_state.daemon_port,
      daemon_pid: backend_state.daemon_pid,
      backend_state: backend_state
    }
  end

  defp context_from_state(%__MODULE__{} = state) do
    backend_state =
      state.backend_state ||
        %ReferenceDBusDaemon{
          tmpdir: state.tmpdir,
          socket_path: state.socket_path,
          bus_address: state.bus_address,
          daemon_port: state.daemon_port,
          daemon_pid: state.daemon_pid
        }

    Context.new(
      scenario_id: "legacy",
      backend_name: :reference,
      backend_mod: ReferenceDBusDaemon,
      backend_state: backend_state
    )
  end

  defp wait_for_ready(port) do
    receive do
      {^port, {:data, data}} ->
        if String.contains?(data, "READY") do
          :ok
        else
          wait_for_ready(port)
        end

      {^port, {:exit_status, code}} ->
        raise "fixture exited with code #{code} before READY"
    after
      @startup_timeout -> raise "fixture did not print READY"
    end
  end

  defp kill_port(nil, _), do: :ok

  defp kill_port(port, os_pid) do
    if os_pid do
      System.cmd("kill", ["-TERM", "#{os_pid}"], stderr_to_stdout: true)
      Process.sleep(100)
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
end
