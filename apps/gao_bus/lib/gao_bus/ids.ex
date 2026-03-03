defmodule GaoBus.Ids do
  @moduledoc """
  Per-boot unique identifiers for the bus daemon.

  Generates a 32-hex-char GUID for auth and a bus instance ID,
  cached in persistent_term so they stay constant for the bus lifetime.
  """

  @guid_key :gao_bus_auth_guid
  @bus_id_key :gao_bus_instance_id

  @doc """
  Returns the auth GUID (32 lowercase hex chars), generating once per boot.
  """
  @spec auth_guid() :: String.t()
  def auth_guid do
    case :persistent_term.get(@guid_key, nil) do
      nil ->
        guid = generate_hex(16)
        :persistent_term.put(@guid_key, guid)
        guid

      guid ->
        guid
    end
  end

  @doc """
  Returns the bus instance ID (32 lowercase hex chars), generating once per boot.
  Tries /etc/machine-id first, falls back to random.
  """
  @spec bus_id() :: String.t()
  def bus_id do
    case :persistent_term.get(@bus_id_key, nil) do
      nil ->
        id = read_machine_id() || generate_hex(16)
        :persistent_term.put(@bus_id_key, id)
        id

      id ->
        id
    end
  end

  defp read_machine_id do
    case File.read("/etc/machine-id") do
      {:ok, content} ->
        id = String.trim(content)
        if byte_size(id) == 32 and String.match?(id, ~r/^[0-9a-f]+$/), do: id

      _ ->
        nil
    end
  end

  defp generate_hex(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
