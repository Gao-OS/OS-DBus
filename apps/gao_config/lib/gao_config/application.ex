defmodule GaoConfig.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    store_path = Application.get_env(:gao_config, :store_path, "/tmp/gao_config.dat")

    children = [
      {GaoConfig.ConfigStore, path: store_path}
    ]

    opts = [strategy: :one_for_one, name: GaoConfig.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
