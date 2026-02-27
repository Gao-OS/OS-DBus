defmodule GaoBusTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :gao_bus_test,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_dbus, in_umbrella: true},
      {:gao_bus, in_umbrella: true},
      {:gao_config, in_umbrella: true},
      {:gao_bus_web, in_umbrella: true},
      {:stream_data, "~> 1.0"},
      {:benchee, "~> 1.0", optional: true}
    ]
  end
end
