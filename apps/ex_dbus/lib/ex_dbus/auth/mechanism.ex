defmodule ExDBus.Auth.Mechanism do
  @moduledoc """
  Behaviour for D-Bus authentication mechanisms.

  D-Bus authentication uses a line-based text protocol before switching
  to the binary wire protocol. Each mechanism implements a state machine
  that processes server responses and generates client commands.

  ## Authentication flow

      Client → Server:  \\0                       (null byte)
      Client → Server:  AUTH EXTERNAL <uid_hex>
      Server → Client:  OK <server_guid>
      Client → Server:  BEGIN
      [switch to binary protocol]
  """

  @type state :: term()

  @doc "Initialize the mechanism state."
  @callback init(opts :: keyword()) :: state()

  @doc """
  Generate the initial AUTH command to send to the server.

  Returns `{:send, line, new_state}` where line is the AUTH command string.
  """
  @callback initial_command(state()) :: {:send, String.t(), state()}

  @doc """
  Handle a response line from the server.

  Returns:
  - `{:send, line, new_state}` — send this line to the server
  - `{:ok, guid, new_state}` — authentication succeeded, guid is the server GUID
  - `{:error, reason}` — authentication failed
  """
  @callback handle_line(line :: String.t(), state()) ::
              {:send, String.t(), state()}
              | {:ok, String.t(), state()}
              | {:error, term()}
end
