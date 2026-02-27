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
      send(self(), :accept)
      {:ok, %{listen_socket: lsock, socket_path: socket_path}}
    else
      {:error, reason} ->
        {:stop, {:listen_failed, reason, socket_path}}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :socket.accept(state.listen_socket, 1_000) do
      {:ok, client_socket} ->
        Logger.debug("GaoBus.Listener: accepted connection")

        case GaoBus.PeerSupervisor.start_peer(client_socket) do
          {:ok, peer_pid} ->
            # Transfer socket ownership to the peer process BEFORE signaling ready.
            # Without this, if the Listener dies, the socket would be closed
            # since the Listener is the owner after accept().
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

      {:error, :timeout} ->
        :ok

      {:error, reason} ->
        Logger.error("GaoBus.Listener: accept error: #{inspect(reason)}")
    end

    send(self(), :accept)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :socket.close(state.listen_socket)
    File.rm(state.socket_path)
    :ok
  end
end
