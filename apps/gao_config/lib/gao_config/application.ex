defmodule GaoConfig.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    store_path = Application.get_env(:gao_config, :store_path, "/tmp/gao_config.dat")

    children = [
      {GaoConfig.ConfigStore, path: store_path}
    ] ++ bus_client_child()

    opts = [strategy: :one_for_one, name: GaoConfig.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp bus_client_child do
    if Application.get_env(:gao_config, :connect_to_bus, false) do
      address = Application.get_env(:gao_config, :bus_address, "unix:path=/tmp/gao_bus_socket")
      [{GaoConfig.BusClient, address: address}]
    else
      []
    end
  end
end
