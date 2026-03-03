defmodule GaoBusTest.ModuleTest do
  use ExUnit.Case

  test "module is loaded" do
    assert Code.ensure_loaded?(GaoBusTest)
  end
end
