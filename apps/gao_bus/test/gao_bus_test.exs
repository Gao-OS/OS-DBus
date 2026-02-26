defmodule GaoBus.Test do
  use ExUnit.Case
  doctest GaoBus

  test "greets the world" do
    assert GaoBus.hello() == :world
  end
end
