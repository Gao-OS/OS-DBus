defmodule GaoBus do
  @moduledoc """
  BEAM-native D-Bus bus daemon.

  Replaces `dbus-daemon` with a supervised Elixir application where every
  D-Bus message is an Erlang message and every connected peer is a GenServer.
  """
end
