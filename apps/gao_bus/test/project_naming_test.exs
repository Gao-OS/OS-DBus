defmodule GaoBus.ProjectNamingTest do
  use ExUnit.Case, async: true

  test "umbrella project uses the GaoBus identity" do
    project_module = GaoBus.Umbrella.MixProject

    assert Code.ensure_loaded?(project_module)

    project = apply(project_module, :project, [])

    assert project[:name] == "GaoBus"
    assert project[:source_url] == "https://github.com/Gao-OS/OS-Bus"
  end
end
