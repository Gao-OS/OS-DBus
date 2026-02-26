defmodule GaoBus.NameRegistry do
  @moduledoc """
  ETS-backed well-known name registry for the D-Bus bus.

  Manages name ownership with RequestName / ReleaseName semantics.
  Emits NameOwnerChanged signals through the Router when ownership changes.
  """

  use GenServer

  import Bitwise

  require Logger

  # RequestName flags
  @flag_allow_replacement 0x1
  @flag_replace_existing 0x2
  @flag_do_not_queue 0x4

  # RequestName return values
  @name_primary_owner 1
  @name_in_queue 2
  @name_exists 3
  @name_already_owner 4

  # ReleaseName return values
  @name_released 1
  @name_non_existent 2
  @name_not_owner 3

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request ownership of a well-known name.

  Returns `{:ok, result_code}` where result_code is one of:
  - 1 = primary owner
  - 2 = in queue
  - 3 = exists (cannot replace)
  - 4 = already owner
  """
  def request_name(name, flags, peer_pid, unique_name) do
    GenServer.call(__MODULE__, {:request_name, name, flags, peer_pid, unique_name})
  end

  @doc """
  Release a well-known name.

  Returns `{:ok, result_code}` where result_code is one of:
  - 1 = released
  - 2 = non-existent
  - 3 = not owner
  """
  def release_name(name, peer_pid) do
    GenServer.call(__MODULE__, {:release_name, name, peer_pid})
  end

  @doc """
  Get the unique name of the owner of a well-known name.
  """
  def get_name_owner(name) do
    GenServer.call(__MODULE__, {:get_name_owner, name})
  end

  @doc """
  List all registered names (well-known + unique).
  """
  def list_names do
    GenServer.call(__MODULE__, :list_names)
  end

  @doc """
  Check if a name exists.
  """
  def name_has_owner?(name) do
    GenServer.call(__MODULE__, {:name_has_owner, name})
  end

  @doc """
  Register a unique name for a peer. Called during Hello().
  """
  def register_unique(unique_name, peer_pid) do
    GenServer.call(__MODULE__, {:register_unique, unique_name, peer_pid})
  end

  @doc """
  Remove all names owned by a peer (called when peer disconnects).
  """
  def peer_disconnected(peer_pid) do
    GenServer.cast(__MODULE__, {:peer_disconnected, peer_pid})
  end

  @doc """
  Resolve a name (well-known or unique) to a peer pid.
  """
  def resolve(name) do
    GenServer.call(__MODULE__, {:resolve, name})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # Well-known names: name => %{owner: pid, unique_name: string, flags: int, queue: []}
    names = :ets.new(:gao_bus_names, [:set, :protected])
    # Unique names: unique_name => pid
    uniques = :ets.new(:gao_bus_uniques, [:set, :protected])
    # Reverse: pid => [owned_names]
    pid_names = :ets.new(:gao_bus_pid_names, [:bag, :protected])

    {:ok, %{names: names, uniques: uniques, pid_names: pid_names}}
  end

  @impl true
  def handle_call({:request_name, name, flags, peer_pid, unique_name}, _from, state) do
    result =
      case :ets.lookup(state.names, name) do
        [] ->
          # Nobody owns it — grant
          :ets.insert(state.names, {name, peer_pid, unique_name, flags, []})
          :ets.insert(state.pid_names, {peer_pid, name})
          emit_name_owner_changed(name, "", unique_name)
          @name_primary_owner

        [{^name, ^peer_pid, _, _, _}] ->
          @name_already_owner

        [{^name, current_pid, current_unique, current_flags, queue}] ->
          can_replace = (current_flags &&& @flag_allow_replacement) != 0
          wants_replace = (flags &&& @flag_replace_existing) != 0

          cond do
            can_replace and wants_replace ->
              # Replace current owner
              :ets.insert(state.names, {name, peer_pid, unique_name, flags, queue})
              :ets.delete_object(state.pid_names, {current_pid, name})
              :ets.insert(state.pid_names, {peer_pid, name})
              emit_name_owner_changed(name, current_unique, unique_name)
              @name_primary_owner

            (flags &&& @flag_do_not_queue) != 0 ->
              @name_exists

            true ->
              # Add to queue
              new_queue = queue ++ [{peer_pid, unique_name, flags}]
              :ets.insert(state.names, {name, current_pid, current_unique, current_flags, new_queue})
              @name_in_queue
          end
      end

    {:reply, {:ok, result}, state}
  end

  def handle_call({:release_name, name, peer_pid}, _from, state) do
    result =
      case :ets.lookup(state.names, name) do
        [] ->
          @name_non_existent

        [{^name, ^peer_pid, unique_name, _flags, queue}] ->
          :ets.delete_object(state.pid_names, {peer_pid, name})

          case queue do
            [] ->
              :ets.delete(state.names, name)
              emit_name_owner_changed(name, unique_name, "")

            [{next_pid, next_unique, next_flags} | rest] ->
              :ets.insert(state.names, {name, next_pid, next_unique, next_flags, rest})
              :ets.insert(state.pid_names, {next_pid, name})
              emit_name_owner_changed(name, unique_name, next_unique)
          end

          @name_released

        _ ->
          @name_not_owner
      end

    {:reply, {:ok, result}, state}
  end

  def handle_call({:get_name_owner, name}, _from, state) do
    result =
      case :ets.lookup(state.names, name) do
        [{^name, _pid, unique_name, _, _}] -> {:ok, unique_name}
        [] ->
          # Check unique names
          case :ets.lookup(state.uniques, name) do
            [{^name, _pid}] -> {:ok, name}
            [] -> {:error, "org.freedesktop.DBus.Error.NameHasNoOwner"}
          end
      end

    {:reply, result, state}
  end

  def handle_call(:list_names, _from, state) do
    well_known = :ets.select(state.names, [{{:"$1", :_, :_, :_, :_}, [], [:"$1"]}])
    unique = :ets.select(state.uniques, [{{:"$1", :_}, [], [:"$1"]}])
    {:reply, ["org.freedesktop.DBus" | well_known ++ unique], state}
  end

  def handle_call({:name_has_owner, name}, _from, state) do
    has_owner =
      name == "org.freedesktop.DBus" or
        :ets.lookup(state.names, name) != [] or
        :ets.lookup(state.uniques, name) != []

    {:reply, has_owner, state}
  end

  def handle_call({:register_unique, unique_name, peer_pid}, _from, state) do
    :ets.insert(state.uniques, {unique_name, peer_pid})
    :ets.insert(state.pid_names, {peer_pid, unique_name})
    emit_name_owner_changed(unique_name, "", unique_name)
    {:reply, :ok, state}
  end

  def handle_call({:resolve, "org.freedesktop.DBus"}, _from, state) do
    {:reply, {:bus, self()}, state}
  end

  def handle_call({:resolve, name}, _from, state) do
    result =
      case :ets.lookup(state.names, name) do
        [{^name, pid, _, _, _}] -> {:ok, pid}
        [] ->
          case :ets.lookup(state.uniques, name) do
            [{^name, pid}] -> {:ok, pid}
            [] -> {:error, :name_not_found}
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:peer_disconnected, peer_pid}, state) do
    # Release all names owned by this peer
    owned = :ets.lookup(state.pid_names, peer_pid)

    for {_pid, name} <- owned do
      case :ets.lookup(state.names, name) do
        [{^name, ^peer_pid, unique_name, _flags, queue}] ->
          case queue do
            [] ->
              :ets.delete(state.names, name)
              emit_name_owner_changed(name, unique_name, "")

            [{next_pid, next_unique, next_flags} | rest] ->
              :ets.insert(state.names, {name, next_pid, next_unique, next_flags, rest})
              :ets.insert(state.pid_names, {next_pid, name})
              emit_name_owner_changed(name, unique_name, next_unique)
          end

        _ ->
          # Remove from queue if queued
          remove_from_queue(state.names, name, peer_pid)
      end

      # Also remove unique name entry
      case :ets.lookup(state.uniques, name) do
        [{^name, ^peer_pid}] ->
          :ets.delete(state.uniques, name)
          emit_name_owner_changed(name, name, "")

        _ ->
          :ok
      end
    end

    :ets.delete(state.pid_names, peer_pid)
    {:noreply, state}
  end

  # --- Helpers ---

  defp remove_from_queue(names_table, name, peer_pid) do
    case :ets.lookup(names_table, name) do
      [{^name, owner, unique, flags, queue}] ->
        new_queue = Enum.reject(queue, fn {pid, _, _} -> pid == peer_pid end)
        :ets.insert(names_table, {name, owner, unique, flags, new_queue})

      _ ->
        :ok
    end
  end

  defp emit_name_owner_changed(name, old_owner, new_owner) do
    # Broadcast to PubSub for web monitor
    cond do
      new_owner != "" and old_owner == "" ->
        GaoBus.PubSub.broadcast({:name_acquired, name, new_owner})
      new_owner == "" and old_owner != "" ->
        GaoBus.PubSub.broadcast({:name_released, name, old_owner})
      true ->
        GaoBus.PubSub.broadcast({:name_acquired, name, new_owner})
    end

    # Send through the router if available
    if Process.whereis(GaoBus.Router) do
      GaoBus.Router.emit_signal(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        "sss",
        [name, old_owner, new_owner]
      )
    end
  end
end
