defmodule GaoBusTest.E2E.Actor.GDBus do
  @moduledoc """
  gdbus command actor.
  """

  alias GaoBusTest.E2E.{Command, Context}

  def available?, do: System.find_executable("gdbus") != nil
  def missing_reason, do: "gdbus not found on PATH"

  def run(%Context{} = context, args, opts \\ []) do
    env = [{"DBUS_SESSION_BUS_ADDRESS", context.bus_address}]

    result =
      Command.run(
        "gdbus",
        args ++ ["--address=#{context.bus_address}"],
        Keyword.merge(opts, env: env)
      )

    {result, Context.add_command(context, result)}
  end
end
