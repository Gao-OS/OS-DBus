defmodule GaoBusWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GaoBusWebWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:gao_bus_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: GaoBusWeb.PubSub},
      # Start a worker by calling: GaoBusWeb.Worker.start_link(arg)
      # {GaoBusWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      GaoBusWebWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GaoBusWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GaoBusWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
