defmodule ExDbus.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Gao-OS/OS-DBus"

  def project do
    [
      app: :ex_dbus,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "ExDBus",
      description: "Pure Elixir D-Bus wire protocol implementation with no C dependencies or NIFs.",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "ExDBus",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end
end
