defmodule GaoBusTest.E2EHarness do
  @moduledoc """
  E2E test harness managing dbus-daemon and fixture service lifecycles.

  Each test group gets an isolated dbus-daemon instance with a private socket.
  The fixture service (C/GLib) is started per-group when E→X tests need it.
  An Elixir service is started per-group when X→E tests need it.
  """

  require Logger

  @dbus_daemon System.find_executable("dbus-daemon")
  @fixture_binary Path.join([__DIR__, "..", "fixture", "external_fixture"])
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
    :elixir_service_conn
  ]

  @doc "Check if required external tools are available."
  def tools_available? do
    @dbus_daemon != nil and
      System.find_executable("busctl") != nil and
      System.find_executable("gdbus") != nil
  end

  @doc "Check if the C fixture binary exists (needs `make -C test/fixture`)."
  def fixture_available? do
    File.exists?(@fixture_binary)
  end

  @doc "Start an isolated dbus-daemon session bus."
  def start_bus do
    tmpdir = Path.join(System.tmp_dir!(), "e2e_dbus_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmpdir)

    socket_path = Path.join(tmpdir, "bus.sock")
    config_path = Path.join(tmpdir, "session.conf")

    config_xml = """
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>custom</type>
      <listen>unix:path=#{socket_path}</listen>
      <auth>EXTERNAL</auth>
      <allow_anonymous/>
      <policy context="default">
        <allow send_destination="*" eavesdrop="true"/>
        <allow eavesdrop="true"/>
        <allow own="*"/>
        <allow send_type="method_call"/>
        <allow send_type="signal"/>
        <allow send_interface="org.freedesktop.DBus.Monitoring"/>
      </policy>
    </busconfig>
    """

    File.write!(config_path, config_xml)

    port =
      Port.open(
        {:spawn_executable, @dbus_daemon},
        [
          :binary,
          :stderr_to_stdout,
          :exit_status,
          args: ["--config-file=#{config_path}", "--nofork", "--print-address"]
        ]
      )

    bus_address = wait_for_bus_address(port)

    {:os_pid, daemon_pid} = Port.info(port, :os_pid)

    state = %__MODULE__{
      tmpdir: tmpdir,
      socket_path: socket_path,
      bus_address: bus_address,
      daemon_port: port,
      daemon_pid: daemon_pid
    }

    {:ok, state}
  end

  @doc "Start the C fixture service on the given bus."
  def start_fixture(%__MODULE__{bus_address: addr} = state) do
    unless fixture_available?() do
      raise "Fixture binary not found at #{@fixture_binary}. Run: make -C apps/gao_bus_test/test/fixture"
    end

    port =
      Port.open(
        {:spawn_executable, @fixture_binary},
        [
          :binary,
          :stderr_to_stdout,
          :exit_status,
          args: ["--bus-address=#{addr}"],
          env: [
            {~c"DBUS_SESSION_BUS_ADDRESS", String.to_charlist(addr)}
          ]
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
      {:ex_dbus, {:connected, _guid}} -> :ok
    after
      @startup_timeout -> raise "Elixir connection to test bus timed out"
    end

    # Say Hello to get a unique name
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

  @doc "Start an Elixir service on the bus (for X→E scenarios)."
  def start_elixir_service(%__MODULE__{bus_address: addr} = state, service_mod) do
    {:ok, conn} =
      ExDBus.Connection.start_link(
        address: addr,
        auth_mod: ExDBus.Auth.External,
        owner: service_mod.owner_pid()
      )

    receive do
      {:ex_dbus, {:connected, _guid}} -> :ok
    after
      @startup_timeout -> raise "Elixir service connection timed out"
    end

    # Hello
    hello =
      ExDBus.Message.method_call(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _} = ExDBus.Connection.call(conn, hello, @tool_timeout)

    # RequestName
    request =
      ExDBus.Message.method_call(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "RequestName",
        destination: "org.freedesktop.DBus",
        signature: "su",
        body: [service_mod.bus_name(), 0]
      )

    {:ok, _} = ExDBus.Connection.call(conn, request, @tool_timeout)

    # Start handling incoming messages
    service_mod.start(conn)

    {:ok, %{state | elixir_service_conn: conn}}
  end

  @doc "Run busctl against the test bus."
  def busctl(%__MODULE__{bus_address: addr}, args, _opts \\ []) do
    System.cmd(
      System.find_executable("busctl"),
      args,
      stderr_to_stdout: true,
      env: [
        {"DBUS_SESSION_BUS_ADDRESS", addr},
        {"DBUS_SYSTEM_BUS_ADDRESS", addr}
      ]
    )
  end

  @doc "Run gdbus against the test bus."
  def gdbus(%__MODULE__{bus_address: addr}, args, _opts \\ []) do
    System.cmd(
      System.find_executable("gdbus"),
      args ++ ["--address=#{addr}"],
      stderr_to_stdout: true,
      env: [
        {"DBUS_SESSION_BUS_ADDRESS", addr}
      ]
    )
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

  @doc "Run dbus-monitor as a background port, returns port."
  def busctl_monitor(%__MODULE__{bus_address: addr}, _match_args \\ []) do
    dbus_monitor = System.find_executable("dbus-monitor")

    Port.open(
      {:spawn_executable, dbus_monitor},
      [
        :binary,
        :stderr_to_stdout,
        args: ["--address", addr]
      ]
    )
  end

  @doc "Tear down everything."
  def cleanup(%__MODULE__{} = state) do
    if state.elixir_conn do
      try do
        ExDBus.Connection.disconnect(state.elixir_conn)
      catch
        _, _ -> :ok
      end
    end

    if state.elixir_service_conn do
      try do
        ExDBus.Connection.disconnect(state.elixir_service_conn)
      catch
        _, _ -> :ok
      end
    end

    kill_port(state.fixture_port, state.fixture_pid)
    kill_port(state.daemon_port, state.daemon_pid)

    if state.tmpdir, do: File.rm_rf!(state.tmpdir)

    :ok
  end

  # --- Private ---

  defp wait_for_bus_address(port) do
    receive do
      {^port, {:data, data}} ->
        case String.trim(data) do
          "unix:" <> _ = addr -> addr
          _ -> wait_for_bus_address(port)
        end

      {^port, {:exit_status, code}} ->
        raise "dbus-daemon exited with code #{code}"
    after
      @startup_timeout -> raise "dbus-daemon did not print address"
    end
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
      # Force kill if still alive
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
end
