defmodule ExDBusTest do
  use ExUnit.Case

  test "module is loaded" do
    assert Code.ensure_loaded?(ExDBus)
  end
end
