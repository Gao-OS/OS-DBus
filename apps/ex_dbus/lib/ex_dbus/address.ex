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
        transport_atom = String.to_atom(transport)

        params =
          params_str
          |> String.split(",")
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn kv ->
            case String.split(kv, "=", parts: 2) do
              [k, v] -> {k, unescape(v)}
              [k] -> {k, ""}
            end
          end)
          |> Enum.into(%{})

        {:ok, {transport_atom, params}}

      _ ->
        {:error, {:invalid_address_format, addr}}
    end
  end

  @doc """
  Get the system bus address.

  Checks `DBUS_SYSTEM_BUS_ADDRESS` env var, falls back to the standard path.
  """
  def system_bus do
    System.get_env("DBUS_SYSTEM_BUS_ADDRESS") ||
      "unix:path=/var/run/dbus/system_bus_socket"
  end

  @doc """
  Get the session bus address.

  Reads from `DBUS_SESSION_BUS_ADDRESS` env var.
  """
  def session_bus do
    System.get_env("DBUS_SESSION_BUS_ADDRESS")
  end

  @doc """
  Determine the transport module for a parsed address.
  """
  def transport_for({:unix, _params}), do: ExDBus.Transport.UnixSocket
  def transport_for({:tcp, _params}), do: ExDBus.Transport.TCP
  def transport_for({type, _}), do: {:error, {:unknown_transport, type}}

  @doc """
  Convert a parsed address back to a connection string for the transport.
  """
  def to_connect_string({:unix, params}) do
    parts = Enum.map_join(params, ",", fn {k, v} -> "#{k}=#{v}" end)
    "unix:#{parts}"
  end

  def to_connect_string({:tcp, params}) do
    parts = Enum.map_join(params, ",", fn {k, v} -> "#{k}=#{v}" end)
    "tcp:#{parts}"
  end

  # D-Bus address values use %xx hex escaping
  defp unescape(value) do
    Regex.replace(~r/%([0-9a-fA-F]{2})/, value, fn _, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end
end
