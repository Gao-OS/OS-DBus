defmodule ExDBus.Transport.Behaviour do
  @moduledoc """
  Behaviour for D-Bus transport implementations.

  A transport provides the raw byte stream between client and server.
  Implementations handle the details of socket creation, connection,
  and I/O for different socket types (Unix, TCP, etc.).
  """

  @type transport :: term()

  @doc "Connect to a D-Bus server at the given address."
  @callback connect(address :: String.t(), opts :: keyword()) ::
              {:ok, transport()} | {:error, term()}

  @doc "Send iodata over the transport."
  @callback send(transport(), iodata()) :: :ok | {:error, term()}

  @doc "Receive data from the transport (blocking)."
  @callback recv(transport(), length :: non_neg_integer(), timeout :: timeout()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Close the transport."
  @callback close(transport()) :: :ok

  @doc "Set the transport to active mode (messages sent to owner process)."
  @callback set_active(transport(), mode :: :once | true | false) :: :ok | {:error, term()}

  @doc "Return the underlying socket for use with :gen_tcp/:socket options."
  @callback socket(transport()) :: port() | :socket.socket()
end
