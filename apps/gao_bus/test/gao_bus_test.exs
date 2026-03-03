defmodule GaoBus.AppTest do
  use ExUnit.Case

  test "application spec is valid" do
    assert {:ok, modules} = :application.get_key(:gao_bus, :modules)
    assert GaoBus.Application in modules
    assert GaoBus.Router in modules
    assert GaoBus.Listener in modules
  end
end
