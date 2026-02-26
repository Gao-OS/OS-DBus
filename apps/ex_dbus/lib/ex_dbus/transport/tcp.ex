defmodule ExDBus.Transport.TCP do
  @moduledoc """
  TCP transport for D-Bus.

  Used for remote D-Bus debugging connections (e.g., connecting to
  a GaoOS device over the network).

  Address format: `tcp:host=<hostname>,port=<port>`
  """

  @behaviour ExDBus.Transport.Behaviour

  defstruct [:socket]

  @impl true
  def connect(address, opts \\ []) do
    {host, port} = parse_address(address)
    timeout = Keyword.get(opts, :timeout, 5_000)

    socket_opts = [:binary, active: false, packet: :raw]

    case :gen_tcp.connect(to_charlist(host), port, socket_opts, timeout) do
      {:ok, socket} ->
        {:ok, %__MODULE__{socket: socket}}

      {:error, reason} ->
        {:error, {:connect_failed, reason, {host, port}}}
    end
  end

  @impl true
  def send(%__MODULE__{socket: socket}, data) do
    :gen_tcp.send(socket, data)
  end

  @impl true
  def recv(%__MODULE__{socket: socket}, length, timeout \\ 5_000) do
    :gen_tcp.recv(socket, length, timeout)
  end

  @impl true
  def close(%__MODULE__{socket: socket}) do
    :gen_tcp.close(socket)
  end

  @impl true
  def set_active(%__MODULE__{socket: socket}, mode) do
    :inet.setopts(socket, active: mode)
  end

  @impl true
  def socket(%__MODULE__{socket: socket}), do: socket

  @doc """
  Parse a D-Bus TCP address string.

  ## Examples

      iex> ExDBus.Transport.TCP.parse_address("tcp:host=localhost,port=12345")
      {"localhost", 12345}
  """
  def parse_address("tcp:" <> params) do
    kv =
      params
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.into(%{}, fn [k, v] -> {k, v} end)

    host = Map.get(kv, "host", "localhost")
    port = Map.get(kv, "port", "0") |> String.to_integer()
    {host, port}
  end

  def parse_address({host, port}) when is_binary(host) and is_integer(port), do: {host, port}
end
