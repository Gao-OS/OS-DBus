defmodule GaoConfigTest do
  use ExUnit.Case
  doctest GaoConfig

  test "greets the world" do
    assert GaoConfig.hello() == :world
  end
end
