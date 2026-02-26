defmodule GaoBus.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    socket_path = Application.get_env(:gao_bus, :socket_path, "/tmp/gao_bus_socket")

    children = [
      {Registry, keys: :unique, name: GaoBus.PeerRegistry},
      GaoBus.NameRegistry,
      GaoBus.MatchRules,
      GaoBus.Policy.Capability,
      GaoBus.Router,
      {GaoBus.PeerSupervisor, []},
      {GaoBus.Listener, socket_path: socket_path}
    ]

    opts = [strategy: :one_for_one, name: GaoBus.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
