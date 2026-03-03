defmodule GaoBus.PeerSupervisor do
  @moduledoc """
  DynamicSupervisor for connected D-Bus peers.

  Each accepted connection gets a supervised `GaoBus.Peer` process.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new Peer process under this supervisor.
  """
  @spec start_peer(:socket.socket()) :: DynamicSupervisor.on_start_child()
  def start_peer(socket) do
    DynamicSupervisor.start_child(__MODULE__, {GaoBus.Peer, socket: socket})
  end
end
