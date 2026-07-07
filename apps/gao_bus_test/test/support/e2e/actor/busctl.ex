defmodule GaoBusTest.E2E.Actor.Busctl do
  @moduledoc """
  busctl command actor.
  """

  alias GaoBusTest.E2E.{Command, Context}

  def available?, do: System.find_executable("busctl") != nil
  def missing_reason, do: "busctl not found on PATH"

  def run(%Context{} = context, args, opts \\ []) do
    env = [
      {"DBUS_SESSION_BUS_ADDRESS", context.bus_address},
      {"DBUS_SYSTEM_BUS_ADDRESS", context.bus_address}
    ]

    result = Command.run("busctl", args, Keyword.merge(opts, env: env))
    {result, Context.add_command(context, result)}
  end
end
