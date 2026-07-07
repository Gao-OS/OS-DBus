defmodule GaoBusTest.E2E.Result.Command do
  @moduledoc """
  Captured result for an external command run by the E2E harness.
  """

  defstruct [
    :command,
    args: [],
    env: [],
    cwd: nil,
    stdout: "",
    stderr: "",
    exit_status: nil,
    duration_ms: 0,
    timed_out?: false
  ]
end

defmodule GaoBusTest.E2E.Result.Oracle do
  @moduledoc """
  Normalized D-Bus semantic outcomes used by conformance scenarios.
  """

  defstruct [
    :kind,
    signature: nil,
    body: [],
    error_name: nil,
    interface: nil,
    member: nil
  ]
end
