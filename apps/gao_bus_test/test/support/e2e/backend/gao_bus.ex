defmodule GaoBusTest.E2E.Backend.GaoBus do
  @moduledoc """
  Isolated gao_bus backend using singleton application restart isolation.
  """

  @behaviour GaoBusTest.E2E.Backend

  alias ExDBus.{Connection, Message}

  @startup_timeout 10_000
  @call_timeout 5_000
  @poll_interval 25

  defstruct [
    :tmpdir,
    :socket_path,
    :bus_address,
    :previous_socket_path,
    :previous_socket_path_set?,
    :was_running?,
    :restored?
  ]

  @impl true
  def start(opts \\ []) do
    case build_state(opts) do
      {:ok, state} ->
        try do
          with {:ok, state} <- restart_app_on_private_socket(state),
               :ok <- wait_until_ready(state) do
            {:ok, state}
          else
            {:error, reason, %__MODULE__{} = state} ->
              stop(state)
              {:error, reason}

            {:error, reason} ->
              stop(state)
              {:error, reason}
          end
        rescue
          exception ->
            stop(state)
            {:error, {:exception, Exception.message(exception)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def address(%__MODULE__{bus_address: address}), do: address

  @impl true
  def probe(%__MODULE__{bus_address: address}) when is_binary(address) do
    case start_probe_connection(address) do
      {:ok, conn} ->
        try do
          with {:ok, hello} <- call_bus(conn, "Hello"),
               true <- unique_name?(hello),
               {:ok, list_names} <- call_bus(conn, "ListNames"),
               true <- dbus_name_present?(list_names) do
            :ok
          else
            false -> {:error, :protocol_probe_failed}
            {:error, reason} -> {:error, {:protocol_probe_failed, reason}}
          end
        after
          disconnect(conn)
        end

      {:error, reason} ->
        {:error, {:protocol_probe_failed, reason}}
    end
  end

  def probe(_state), do: {:error, :missing_bus_address}

  @impl true
  def diagnostics(%__MODULE__{} = state) do
    app_running? = app_running?()
    registered_names = registered_names(app_running?)
    peer_count = peer_count(app_running?)

    %{
      backend: "gao_bus",
      tmpdir: state.tmpdir,
      socket_path: state.socket_path,
      bus_address: state.bus_address,
      app_running?: app_running?,
      registered_names: registered_names,
      peer_count: peer_count,
      log: """
      backend=gao_bus
      socket_path=#{state.socket_path}
      bus_address=#{state.bus_address}
      app_running?=#{inspect(app_running?)}
      registered_names=#{inspect(registered_names)}
      peer_count=#{inspect(peer_count)}
      """
    }
  end

  @impl true
  def stop(%__MODULE__{restored?: true}), do: :ok

  def stop(%__MODULE__{} = state) do
    unless already_restored?(state) do
      Application.stop(:gao_bus)
      restore_socket_path_env(state)
      restore_previous_app_state(state)
      if state.tmpdir, do: File.rm_rf(state.tmpdir)
    end

    :ok
  end

  def stop(_), do: :ok

  defp build_state(opts) do
    base = Keyword.get(opts, :tmp_base, System.tmp_dir!())
    tmpdir = Path.join(base, "gb#{System.unique_integer([:positive])}")
    socket_path = Path.join(tmpdir, "s")

    with :ok <- File.mkdir_p(tmpdir) do
      {previous_socket_path_set?, previous_socket_path} =
        case Application.fetch_env(:gao_bus, :socket_path) do
          {:ok, value} -> {true, value}
          :error -> {false, nil}
        end

      {:ok,
       %__MODULE__{
         tmpdir: tmpdir,
         socket_path: socket_path,
         bus_address: "unix:path=#{socket_path}",
         previous_socket_path: previous_socket_path,
         previous_socket_path_set?: previous_socket_path_set?,
         was_running?: app_running?(),
         restored?: false
       }}
    else
      {:error, reason} -> {:error, {:tmpdir_create_failed, reason}}
    end
  end

  defp restart_app_on_private_socket(%__MODULE__{} = state) do
    Application.stop(:gao_bus)
    Application.put_env(:gao_bus, :socket_path, state.socket_path)

    case Application.ensure_all_started(:gao_bus) do
      {:ok, _started} -> {:ok, state}
      {:error, reason} -> {:error, {:app_start_failed, reason}, state}
    end
  end

  defp wait_until_ready(%__MODULE__{} = state) do
    deadline = System.monotonic_time(:millisecond) + @startup_timeout
    wait_until_ready(state, deadline, nil)
  end

  defp wait_until_ready(%__MODULE__{} = state, deadline, last_error) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {:error, {:gao_bus_ready_timeout, last_error}, state}

      not File.exists?(state.socket_path) ->
        poll_pause()
        wait_until_ready(state, deadline, :socket_not_created)

      true ->
        case probe(state) do
          :ok ->
            :ok

          {:error, reason} ->
            poll_pause()
            wait_until_ready(state, deadline, reason)
        end
    end
  end

  defp start_probe_connection(address) do
    case Connection.start_link(address: address, auth_mod: ExDBus.Auth.External, owner: self()) do
      {:ok, conn} ->
        receive do
          {:ex_d_bus, {:connected, _guid}} -> {:ok, conn}
        after
          @startup_timeout ->
            disconnect(conn)
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

  defp disconnect(conn) do
    Connection.disconnect(conn)
  catch
    _, _ -> :ok
  end

  defp restore_socket_path_env(%__MODULE__{previous_socket_path_set?: true} = state) do
    Application.put_env(:gao_bus, :socket_path, state.previous_socket_path)
  end

  defp restore_socket_path_env(%__MODULE__{previous_socket_path_set?: false}) do
    Application.delete_env(:gao_bus, :socket_path)
  end

  defp restore_previous_app_state(%__MODULE__{was_running?: true}) do
    Application.ensure_all_started(:gao_bus)
    :ok
  end

  defp restore_previous_app_state(%__MODULE__{was_running?: false}), do: :ok

  defp already_restored?(%__MODULE__{} = state) do
    env_restored? =
      case Application.fetch_env(:gao_bus, :socket_path) do
        {:ok, value} -> value != state.socket_path
        :error -> true
      end

    tmpdir_removed? = state.tmpdir && not File.exists?(state.tmpdir)

    env_restored? and tmpdir_removed?
  end

  defp app_running? do
    Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :gao_bus end)
  end

  defp registered_names(true) do
    if Process.whereis(GaoBus.NameRegistry), do: GaoBus.NameRegistry.list_names(), else: []
  rescue
    _ -> []
  end

  defp registered_names(false), do: []

  defp peer_count(true) do
    case Process.whereis(GaoBus.Router) do
      nil ->
        nil

      _pid ->
        GaoBus.Router
        |> :sys.get_state()
        |> Map.get(:peers, %{})
        |> map_size()
    end
  rescue
    _ -> nil
  end

  defp peer_count(false), do: nil

  defp poll_pause do
    receive do
    after
      @poll_interval -> :ok
    end
  end
end
