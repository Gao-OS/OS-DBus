defmodule GaoBus.Listener do
  @moduledoc """
  Accepts D-Bus connections on a Unix domain socket.

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

    case :gen_tcp.listen(0, [
           :binary,
           active: false,
           packet: :raw,
           reuseaddr: true,
           ifaddr: {:local, socket_path}
         ]) do
      {:ok, listen_socket} ->
        Logger.info("GaoBus.Listener: listening on #{socket_path}")
        send(self(), :accept)
        {:ok, %{listen_socket: listen_socket, socket_path: socket_path}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason, socket_path}}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, 1_000) do
      {:ok, client_socket} ->
        Logger.debug("GaoBus.Listener: accepted connection")

        case GaoBus.PeerSupervisor.start_peer(client_socket) do
          {:ok, peer_pid} ->
            :gen_tcp.controlling_process(client_socket, peer_pid)
            send(peer_pid, :socket_ready)

          {:error, reason} ->
            Logger.error("GaoBus.Listener: failed to start peer: #{inspect(reason)}")
            :gen_tcp.close(client_socket)
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
    :gen_tcp.close(state.listen_socket)
    File.rm(state.socket_path)
    :ok
  end
end
