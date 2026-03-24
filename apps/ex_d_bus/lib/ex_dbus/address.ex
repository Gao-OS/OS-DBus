defmodule ExDBus.Address do
  @moduledoc """
  Parse D-Bus address strings.

  D-Bus addresses specify how to connect to a bus. They follow the format:
  `transport:key1=val1,key2=val2;transport2:key3=val3`

  Multiple addresses can be separated by `;` for fallback behavior.

  ## Common addresses

  - `unix:path=/var/run/dbus/system_bus_socket` — system bus
  - `unix:abstract=/tmp/dbus-xxxxx` — session bus (abstract socket)
  - `tcp:host=localhost,port=12345` — remote debugging
  """

  @doc """
  Parse a D-Bus address string into a list of {transport_type, params} tuples.

  ## Examples

      iex> ExDBus.Address.parse("unix:path=/var/run/dbus/system_bus_socket")
      {:ok, [{:unix, %{"path" => "/var/run/dbus/system_bus_socket"}}]}

      iex> ExDBus.Address.parse("tcp:host=localhost,port=12345")
      {:ok, [{:tcp, %{"host" => "localhost", "port" => "12345"}}]}
  """
  @type parsed_address :: {atom(), %{optional(String.t()) => String.t()}}

  @spec parse(String.t()) :: {:ok, [parsed_address()]} | {:error, term()}
  def parse(address) when is_binary(address) do
    addresses =
      address
      |> String.split(";")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_single/1)

    if Enum.any?(addresses, &match?({:error, _}, &1)) do
      {:error, {:invalid_address, address}}
    else
      {:ok, Enum.map(addresses, fn {:ok, addr} -> addr end)}
    end
  end

  defp parse_single(addr) do
    case String.split(addr, ":", parts: 2) do
      [transport, params_str] ->
        case to_transport_atom(transport) do
          {:error, _} = error ->
            error

          transport_atom ->
            params = parse_params(params_str)
            {:ok, {transport_atom, params}}
        end

      _ ->
        {:error, {:invalid_address_format, addr}}
    end
  end

  @doc """
  Get the system bus address.

  Checks `DBUS_SYSTEM_BUS_ADDRESS` env var, falls back to the standard path.
  """
  @spec system_bus() :: String.t()
  def system_bus do
    System.get_env("DBUS_SYSTEM_BUS_ADDRESS") ||
      "unix:path=/var/run/dbus/system_bus_socket"
  end

  @doc """
  Get the session bus address.

  Reads from `DBUS_SESSION_BUS_ADDRESS` env var.
  """
  @spec session_bus() :: String.t() | nil
  def session_bus do
    System.get_env("DBUS_SESSION_BUS_ADDRESS")
  end

  @doc """
  Determine the transport module for a parsed address.
  """
  @spec transport_for(parsed_address()) :: module() | {:error, {:unknown_transport, atom()}}
  def transport_for({:unix, _params}), do: ExDBus.Transport.UnixSocket
  def transport_for({:tcp, _params}), do: ExDBus.Transport.TCP
  def transport_for({type, _}), do: {:error, {:unknown_transport, type}}

  @doc """
  Convert a parsed address back to a connection string for the transport.
  """
  @spec to_connect_string(parsed_address()) :: String.t()
  def to_connect_string({:unix, params}) do
    parts = Enum.map_join(params, ",", fn {k, v} -> "#{k}=#{v}" end)
    "unix:#{parts}"
  end

  def to_connect_string({:tcp, params}) do
    parts = Enum.map_join(params, ",", fn {k, v} -> "#{k}=#{v}" end)
    "tcp:#{parts}"
  end

  @known_transports ~w(unix tcp nonce-tcp unixexec launchd autolaunch)
  defp to_transport_atom(transport) when transport in @known_transports do
    String.to_existing_atom(transport)
  end

  defp to_transport_atom(transport), do: {:error, {:unknown_transport, transport}}

  defp parse_params(params_str) do
    params_str
    |> String.split(",")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> {k, unescape(v)}
        [k] -> {k, ""}
      end
    end)
    |> Map.new()
  end

  defp unescape(value) do
    Regex.replace(~r/%([0-9a-fA-F]{2})/, value, fn _, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end
end
