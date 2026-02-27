defmodule GaoConfig.ConfigStore do
  @moduledoc """
  ETS-backed configuration store with disk persistence.

  Stores configuration as {section, key} => value tuples.
  Persists to disk using `:erlang.term_to_binary` for crash recovery.
  """

  use GenServer

  require Logger

  @table :gao_config_store

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a config value by section and key.
  """
  def get(section, key) do
    case :ets.lookup(@table, {section, key}) do
      [{{^section, ^key}, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Set a config value.
  """
  def set(section, key, value) do
    GenServer.call(__MODULE__, {:set, section, key, value})
  end

  @doc """
  Delete a config value.
  """
  def delete(section, key) do
    GenServer.call(__MODULE__, {:delete, section, key})
  end

  @doc """
  Clear all entries. Used by tests.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  List all keys in a section.
  """
  def list(section) do
    matches = :ets.match(@table, {{section, :"$1"}, :"$2"})
    Enum.map(matches, fn [key, value] -> {key, value} end)
  end

  @doc """
  List all sections.
  """
  def list_sections do
    :ets.foldl(
      fn {{section, _key}, _value}, acc -> MapSet.put(acc, section) end,
      MapSet.new(),
      @table
    )
    |> MapSet.to_list()
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, "/tmp/gao_config.dat")
    table = :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])

    # Load from disk if available
    load_from_disk(path)

    {:ok, %{table: table, path: path}}
  end

  @impl true
  def handle_call({:set, section, key, value}, _from, state) do
    :ets.insert(@table, {{section, key}, value})
    persist(state.path)
    notify_change(section, key, value)
    {:reply, :ok, state}
  end

  def handle_call({:delete, section, key}, _from, state) do
    :ets.delete(@table, {section, key})
    persist(state.path)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    persist(state.path)
    :ok
  end

  # --- Persistence ---

  defp load_from_disk(path) do
    case File.read(path) do
      {:ok, data} ->
        try do
          entries = :erlang.binary_to_term(data)
          Enum.each(entries, fn entry -> :ets.insert(@table, entry) end)
          Logger.debug("GaoConfig: loaded #{length(entries)} entries from #{path}")
        rescue
          _ -> Logger.warning("GaoConfig: corrupt data file at #{path}, starting fresh")
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("GaoConfig: could not read #{path}: #{inspect(reason)}")
    end
  end

  defp persist(path) do
    entries = :ets.tab2list(@table)
    data = :erlang.term_to_binary(entries)

    case File.write(path, data) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("GaoConfig: failed to persist to #{path}: #{inspect(reason)}")
    end
  end

  defp notify_change(section, key, value) do
    # Broadcast via PubSub if gao_bus is available (use apply to avoid compile-time dep)
    if Code.ensure_loaded?(GaoBus.PubSub) and function_exported?(GaoBus.PubSub, :broadcast, 1) do
      apply(GaoBus.PubSub, :broadcast, [{:config_changed, section, key, value}])
    end
  end
end
