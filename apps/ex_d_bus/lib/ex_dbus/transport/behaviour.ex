defmodule ExDBus.Transport.Behaviour do
  @moduledoc """
  Behaviour for D-Bus transport implementations.

  A transport provides the raw byte stream between client and server.
  Implementations handle the details of socket creation, connection,
  and I/O for different socket types (Unix, TCP, etc.).

  ## Optional FD Passing

  Transports over Unix domain sockets may support file descriptor passing
  via SCM_RIGHTS. Implement the optional callbacks `supports_fd_passing?/1`
  and `send_with_fds/3` to enable this.
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

  # --- Optional FD passing callbacks ---

  @doc "Whether the transport supports Unix FD passing via SCM_RIGHTS."
  @callback supports_fd_passing?(transport()) :: boolean()

  @doc "Send iodata with file descriptors via SCM_RIGHTS."
  @callback send_with_fds(transport(), iodata(), fds :: [non_neg_integer()]) ::
              :ok | {:error, term()}

  @optional_callbacks [supports_fd_passing?: 1, send_with_fds: 3]
end
