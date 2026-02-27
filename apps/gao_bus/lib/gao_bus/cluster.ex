defmodule GaoBus.Cluster do
  @moduledoc """
  Distributed bus support for multi-node BEAM clustering.

  Enables D-Bus messages to be routed across multiple BEAM nodes,
  allowing services registered on one node to be called from another.

  ## Architecture

  Each node runs its own `GaoBus.Supervisor` with a local bus. The Cluster
  module synchronizes well-known name registrations across nodes and forwards
  messages to remote peers when the destination is registered on another node.

  ## Design Decisions

  - Names are node-local by default; cross-node routing requires explicit join
  - Uses Erlang distribution (`:pg` process groups) for node discovery
  - Remote method_calls are forwarded as-is; the caller sees the same reply
  - Signals are optionally broadcast across nodes (configurable)

  ## Usage

      # In config.exs
      config :gao_bus, cluster: true

      # At runtime, nodes auto-discover via :pg
  """

  use GenServer

  require Logger

  alias ExDBus.Message

  @pg_group :gao_bus_cluster
  @scope :gao_bus_pg

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Forward a message to a remote node where the destination name is registered.

  Returns `{:ok, :forwarded}` if sent, `{:error, :not_found}` if no remote node has it.
  """
  def route_remote(%Message{destination: dest} = msg) when is_binary(dest) do
    case find_remote_owner(dest) do
      {:ok, {node, remote_pid}} ->
        GenServer.cast({__MODULE__, node}, {:forward_message, msg, remote_pid})
        {:ok, :forwarded}

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Register a well-known name on this node so remote nodes can find it.
  """
  def register_name(name, peer_pid) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:register_name, name, peer_pid})
    end
  end

  @doc """
  Unregister a well-known name from cluster visibility.
  """
  def unregister_name(name) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:unregister_name, name})
    end
  end

  @doc """
  List all names known across the cluster.

  Returns `[{name, node}]` tuples.
  """
  def cluster_names do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :cluster_names)
    else
      []
    end
  end

  @doc """
  List connected cluster nodes.
  """
  def nodes do
    members = :pg.get_members(@scope, @pg_group)

    members
    |> Enum.map(&node/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == Kernel.node()))
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # Start :pg scope if not already running
    case :pg.start_link(@scope) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Join the cluster group
    :pg.join(@scope, @pg_group, self())

    # Monitor node connections/disconnections
    :net_kernel.monitor_nodes(true)

    Logger.info("GaoBus.Cluster: joined cluster as #{Kernel.node()}")

    {:ok, %{remote_names: %{}, local_names: %{}}}
  end

  @impl true
  def handle_cast({:register_name, name, peer_pid}, state) do
    local_names = Map.put(state.local_names, name, peer_pid)

    # Broadcast to other nodes
    broadcast_to_peers({:name_registered, Kernel.node(), name})

    {:noreply, %{state | local_names: local_names}}
  end

  def handle_cast({:unregister_name, name}, state) do
    local_names = Map.delete(state.local_names, name)

    # Broadcast to other nodes
    broadcast_to_peers({:name_unregistered, Kernel.node(), name})

    {:noreply, %{state | local_names: local_names}}
  end

  def handle_cast({:forward_message, msg, target_pid}, state) do
    # Deliver message to the local peer
    send(target_pid, {:send_message, msg})
    {:noreply, state}
  end

  def handle_cast({:cluster_event, {:name_registered, remote_node, name}}, state) do
    Logger.debug("GaoBus.Cluster: #{remote_node} registered #{name}")
    remote_names = Map.put(state.remote_names, name, remote_node)
    {:noreply, %{state | remote_names: remote_names}}
  end

  def handle_cast({:cluster_event, {:name_unregistered, remote_node, name}}, state) do
    Logger.debug("GaoBus.Cluster: #{remote_node} unregistered #{name}")

    remote_names =
      case Map.get(state.remote_names, name) do
        ^remote_node -> Map.delete(state.remote_names, name)
        _ -> state.remote_names
      end

    {:noreply, %{state | remote_names: remote_names}}
  end

  def handle_cast({:cluster_event, {:sync_request, from_node, from_pid}}, state) do
    # Send our local names to the requesting node
    for {name, _pid} <- state.local_names do
      GenServer.cast(from_pid, {:cluster_event, {:name_registered, Kernel.node(), name}})
    end

    Logger.debug("GaoBus.Cluster: synced #{map_size(state.local_names)} names to #{from_node}")
    {:noreply, state}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:cluster_names, _from, state) do
    local = Enum.map(state.local_names, fn {name, _pid} -> {name, Kernel.node()} end)
    remote = Enum.map(state.remote_names, fn {name, node} -> {name, node} end)
    {:reply, local ++ remote, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("GaoBus.Cluster: node connected: #{node}")

    # Request name sync from the new node
    request_sync_from(node)

    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.info("GaoBus.Cluster: node disconnected: #{node}")

    # Remove all names from the disconnected node
    remote_names =
      state.remote_names
      |> Enum.reject(fn {_name, n} -> n == node end)
      |> Map.new()

    {:noreply, %{state | remote_names: remote_names}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private helpers ---

  defp find_remote_owner(name) do
    if Process.whereis(__MODULE__) do
      case GenServer.call(__MODULE__, :cluster_names) do
        names when is_list(names) ->
          case List.keyfind(names, name, 0) do
            {^name, remote_node} when remote_node != Kernel.node() ->
              # Resolve the name on the remote node
              case :rpc.call(remote_node, GaoBus.NameRegistry, :resolve, [name]) do
                {:ok, pid} -> {:ok, {remote_node, pid}}
                _ -> :not_found
              end

            _ ->
              :not_found
          end

        _ ->
          :not_found
      end
    else
      :not_found
    end
  end

  defp broadcast_to_peers(event) do
    peers = :pg.get_members(@scope, @pg_group)

    for pid <- peers, pid != self() do
      GenServer.cast(pid, {:cluster_event, event})
    end
  end

  defp request_sync_from(node) do
    peers = :pg.get_members(@scope, @pg_group)

    for pid <- peers, node(pid) == node do
      GenServer.cast(pid, {:cluster_event, {:sync_request, Kernel.node(), self()}})
    end
  end
end
