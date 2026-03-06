defmodule GaoBus.Listener do
  @moduledoc """
  Accepts D-Bus connections on a Unix domain socket.

  Uses the Erlang `:socket` module (not `:gen_tcp`) to support
  SCM_RIGHTS file descriptor passing required by the D-Bus spec.

  Listens on a configurable path (default: /tmp/gao_bus_socket for dev).
  Each accepted connection is handed off to a Peer process under PeerSupervisor.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.fetch!(opts, :socket_path)

    # Remove stale socket file
    File.rm(socket_path)

    with {:ok, lsock} <- :socket.open(:local, :stream, :default),
         :ok <- :socket.bind(lsock, %{family: :local, path: socket_path}),
         :ok <- :socket.listen(lsock) do
      Logger.info("GaoBus.Listener: listening on #{socket_path}")
      state = %{listen_socket: lsock, socket_path: socket_path}
      async_accept(state)
      {:ok, state}
    else
      {:error, reason} ->
        {:stop, {:listen_failed, reason, socket_path}}
    end
  end

  @impl true
  # Select notification: the listen socket has an incoming connection ready
  def handle_info({:"$socket", socket, :select, _info}, %{listen_socket: socket} = state) do
    case :socket.accept(socket, :nowait) do
      {:ok, client_socket} ->
        Logger.debug("GaoBus.Listener: accepted connection")
        hand_off_socket(client_socket)
        async_accept(state)

      {:select, _select_info} ->
        # Spurious wakeup — another async accept is already pending
        :ok

      {:error, reason} ->
        Logger.error("GaoBus.Listener: accept error: #{inspect(reason)}")
        async_accept(state)
    end

    {:noreply, state}
  end

  # Completion notification (some OTP versions deliver accepted socket this way)
  def handle_info(
        {:completion, {socket, _info}, {:ok, client_socket}},
        %{listen_socket: socket} = state
      ) do
    Logger.debug("GaoBus.Listener: accepted connection (completion)")
    hand_off_socket(client_socket)
    async_accept(state)
    {:noreply, state}
  end

  def handle_info(
        {:completion, {socket, _info}, {:error, reason}},
        %{listen_socket: socket} = state
      ) do
    Logger.error("GaoBus.Listener: accept completion error: #{inspect(reason)}")
    async_accept(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Initiate a non-blocking accept. When a connection arrives, the runtime
  # sends a select (or completion) message to this process.
  defp async_accept(%{listen_socket: lsock}) do
    case :socket.accept(lsock, :nowait) do
      {:ok, client_socket} ->
        # Connection already waiting — handle immediately and queue next accept
        Logger.debug("GaoBus.Listener: accepted connection (immediate)")
        hand_off_socket(client_socket)
        async_accept(%{listen_socket: lsock})

      {:select, _select_info} ->
        # Will receive {:'$socket', lsock, :select, info} when a connection arrives
        :ok

      {:error, reason} ->
        Logger.error("GaoBus.Listener: async accept error: #{inspect(reason)}")
        :ok
    end
  end

  defp hand_off_socket(client_socket) do
    case GaoBus.PeerSupervisor.start_peer(client_socket) do
      {:ok, peer_pid} ->
        case :socket.setopt(client_socket, {:otp, :controlling_process}, peer_pid) do
          :ok ->
            send(peer_pid, :socket_ready)

          {:error, reason} ->
            Logger.error("GaoBus.Listener: failed to transfer socket: #{inspect(reason)}")
            :socket.close(client_socket)
        end

      {:error, reason} ->
        Logger.error("GaoBus.Listener: failed to start peer: #{inspect(reason)}")
        :socket.close(client_socket)
    end
  end

  @impl true
  def terminate(_reason, state) do
    :socket.close(state.listen_socket)
    File.rm(state.socket_path)
    :ok
  end
end
