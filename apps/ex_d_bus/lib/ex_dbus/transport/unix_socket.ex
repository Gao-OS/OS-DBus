defmodule ExDBus.Transport.UnixSocket do
  @moduledoc """
  Unix domain socket transport for D-Bus.

  Supports both filesystem paths and abstract sockets.
  Handles AF_UNIX SOCK_STREAM connections.
  """

  @behaviour ExDBus.Transport.Behaviour

  @type t :: %__MODULE__{socket: port() | nil}

  defstruct [:socket]

  @impl true
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(address, opts \\ []) do
    path = parse_address(address)
    timeout = Keyword.get(opts, :timeout, 5_000)

    socket_opts = [:binary, active: false, packet: :raw]

    case :gen_tcp.connect({:local, path}, 0, socket_opts, timeout) do
      {:ok, socket} ->
        {:ok, %__MODULE__{socket: socket}}

      {:error, reason} ->
        {:error, {:connect_failed, reason, path}}
    end
  end

  @impl true
  @spec send(t(), iodata()) :: :ok | {:error, term()}
  def send(%__MODULE__{socket: socket}, data) do
    :gen_tcp.send(socket, data)
  end

  @impl true
  @spec recv(t(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv(%__MODULE__{socket: socket}, length, timeout \\ 5_000) do
    :gen_tcp.recv(socket, length, timeout)
  end

  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket}) do
    :gen_tcp.close(socket)
  end

  @impl true
  @spec set_active(t(), :once | true | false) :: :ok | {:error, term()}
  def set_active(%__MODULE__{socket: socket}, mode) do
    :inet.setopts(socket, active: mode)
  end

  @impl true
  @spec socket(t()) :: port()
  def socket(%__MODULE__{socket: socket}), do: socket

  @doc """
  Parse a D-Bus address string to extract the socket path.

  Supports formats:
  - `unix:path=/var/run/dbus/system_bus_socket`
  - `unix:abstract=/tmp/dbus-xxx`
  - A bare path (convenience)

  ## Examples

      iex> ExDBus.Transport.UnixSocket.parse_address("unix:path=/var/run/dbus/system_bus_socket")
      "/var/run/dbus/system_bus_socket"

      iex> ExDBus.Transport.UnixSocket.parse_address("/tmp/my_socket")
      "/tmp/my_socket"
  """
  @spec parse_address(String.t()) :: String.t()
  def parse_address("unix:" <> params) do
    params
    |> String.split(",")
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Map.new(fn
      [k, v] -> {k, v}
      [k] -> {k, ""}
    end)
    |> case do
      %{"path" => path} -> path
      %{"abstract" => name} -> <<0>> <> name
      other -> raise ArgumentError, "Unsupported unix address params: #{inspect(other)}"
    end
  end

  def parse_address(path) when is_binary(path), do: path
end
