defmodule GaoBusWebWeb.MessagesLiveTest do
  use ExUnit.Case

  test "module exists and is a LiveView" do
    Code.ensure_loaded!(GaoBusWebWeb.MessagesLive)
    assert function_exported?(GaoBusWebWeb.MessagesLive, :mount, 3)
    assert function_exported?(GaoBusWebWeb.MessagesLive, :render, 1)
  end
end
