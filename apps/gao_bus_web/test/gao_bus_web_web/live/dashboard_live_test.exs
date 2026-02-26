defmodule GaoBusWebWeb.DashboardLiveTest do
  use ExUnit.Case

  test "module exists and is a LiveView" do
    Code.ensure_loaded!(GaoBusWebWeb.DashboardLive)
    assert function_exported?(GaoBusWebWeb.DashboardLive, :mount, 3)
    assert function_exported?(GaoBusWebWeb.DashboardLive, :render, 1)
  end
end
