defmodule GaoBusTest.E2E.Backend.ReferenceDBusDaemon do
  @moduledoc """
  Isolated reference backend powered by dbus-daemon.
  """

  @behaviour GaoBusTest.E2E.Backend

  alias ExDBus.{Connection, Message}

  @startup_timeout 10_000
  @call_timeout 5_000

  defstruct [
    :tmpdir,
    :socket_path,
    :config_path,
    :bus_address,
    :daemon_path,
    :daemon_port,
    :daemon_pid,
    stdout: "",
    stderr: ""
  ]

  @impl true
  def start(opts \\ []) do
    with {:ok, daemon_path} <- find_daemon(),
         {:ok, state} <- build_state(daemon_path, opts),
         :ok <- write_config(state),
         {:ok, state} <- start_daemon(state),
         :ok <- probe(state) do
      {:ok, state}
    else
      {:error, reason, %__MODULE__{} = state} ->
        stop(state)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def address(%__MODULE__{bus_address: address}), do: address

  @impl true
  def probe(%__MODULE__{bus_address: address}) when is_binary(address) do
    with {:ok, conn} <- start_probe_connection(address),
         {:ok, hello} <- call_bus(conn, "Hello"),
         true <- unique_name?(hello),
         {:ok, list_names} <- call_bus(conn, "ListNames"),
         true <- dbus_name_present?(list_names) do
      Connection.disconnect(conn)
      :ok
    else
      false -> {:error, :protocol_probe_failed}
      {:error, reason} -> {:error, {:protocol_probe_failed, reason}}
    end
  end

  def probe(_state), do: {:error, :missing_bus_address}

  @impl true
  def diagnostics(%__MODULE__{} = state) do
    drained = drain_port(state.daemon_port, "")
    log = state.stdout <> drained

    %{
      backend: "reference",
      tmpdir: state.tmpdir,
      socket_path: state.socket_path,
      bus_address: state.bus_address,
      daemon_path: state.daemon_path,
      daemon_pid: state.daemon_pid,
      log: """
      backend=reference
      socket_path=#{state.socket_path}
      bus_address=#{state.bus_address}
      daemon_path=#{state.daemon_path}
      daemon_pid=#{inspect(state.daemon_pid)}
      daemon_output=#{inspect(log)}
      """
    }
  end

  @impl true
  def stop(%__MODULE__{} = state) do
    kill_port(state.daemon_port, state.daemon_pid)
    if state.tmpdir, do: File.rm_rf(state.tmpdir)
    :ok
  end

  def stop(_), do: :ok

  defp find_daemon do
    case System.find_executable("dbus-daemon") do
      nil -> {:error, {:missing_executable, "dbus-daemon"}}
      path -> {:ok, path}
    end
  end

  defp build_state(daemon_path, opts) do
    base = Keyword.get(opts, :tmp_base, System.tmp_dir!())
    tmpdir = Path.join(base, "e2e_dbus_#{System.unique_integer([:positive])}")
    socket_path = Path.join(tmpdir, "bus.sock")
    config_path = Path.join(tmpdir, "session.conf")

    File.mkdir_p!(tmpdir)

    {:ok,
     %__MODULE__{
       tmpdir: tmpdir,
       socket_path: socket_path,
       config_path: config_path,
       daemon_path: daemon_path
     }}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp write_config(%__MODULE__{} = state) do
    File.write!(state.config_path, config_xml(state.socket_path))
    :ok
  rescue
    exception -> {:error, Exception.message(exception), state}
  end

  defp start_daemon(%__MODULE__{} = state) do
    port =
      Port.open(
        {:spawn_executable, state.daemon_path},
        [
          :binary,
          :stderr_to_stdout,
          :exit_status,
          args: ["--config-file=#{state.config_path}", "--nofork", "--print-address"]
        ]
      )

    with {:ok, address, output} <- wait_for_bus_address(port, ""),
         {:os_pid, daemon_pid} <- Port.info(port, :os_pid) do
      {:ok,
       %{state | daemon_port: port, daemon_pid: daemon_pid, bus_address: address, stdout: output}}
    else
      {:error, reason, output} ->
        {:error, reason, %{state | daemon_port: port, stdout: output}}

      other ->
        {:error, {:daemon_start_failed, other}, %{state | daemon_port: port}}
    end
  end

  defp config_xml(socket_path) do
    """
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
  end

  defp wait_for_bus_address(port, acc) do
    receive do
      {^port, {:data, data}} ->
        output = acc <> data

        case output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "unix:")) do
          nil -> wait_for_bus_address(port, output)
          address -> {:ok, String.trim(address), output}
        end

      {^port, {:exit_status, code}} ->
        {:error, {:dbus_daemon_exited, code}, acc}
    after
      @startup_timeout -> {:error, :dbus_daemon_address_timeout, acc}
    end
  end

  defp start_probe_connection(address) do
    case Connection.start_link(address: address, auth_mod: ExDBus.Auth.External, owner: self()) do
      {:ok, conn} ->
        receive do
          {:ex_d_bus, {:connected, _guid}} -> {:ok, conn}
        after
          @startup_timeout ->
            Connection.disconnect(conn)
            {:error, :connection_timeout}
        end

      {:error, _} = error ->
        error
    end
  end

  defp call_bus(conn, member) do
    msg =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", member,
        destination: "org.freedesktop.DBus"
      )

    Connection.call(conn, msg, @call_timeout)
  end

  defp unique_name?(%Message{body: [":" <> _]}), do: true
  defp unique_name?(_), do: false

  defp dbus_name_present?(%Message{body: [names]}) when is_list(names) do
    "org.freedesktop.DBus" in names
  end

  defp dbus_name_present?(_), do: false

  defp drain_port(nil, acc), do: acc

  defp drain_port(port, acc) do
    receive do
      {^port, {:data, data}} -> drain_port(port, acc <> data)
      {^port, {:exit_status, code}} -> acc <> "\n[exit_status #{code}]\n"
    after
      0 -> acc
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
