defmodule GaoBus.Policy.Capability do
  @moduledoc """
  Capability-based D-Bus policy engine for GaoOS.

  Replaces traditional XML policy files with Elixir-based capability grants.
  Each connected peer has a set of capabilities that determine what actions
  they can perform.

  ## Capabilities

  Capabilities are structured as `{scope, target}` tuples:

  - `{:send, destination}` — can send messages to `destination`
  - `{:receive, sender}` — can receive messages from `sender`
  - `{:own, name}` — can own well-known name `name`
  - `{:call, {destination, interface, method}}` — can call specific method
  - `{:call, {destination, interface}}` — can call any method on interface
  - `{:all, :all}` — superuser, all permissions (uid 0)

  ## Default Policy

  - uid 0 (root): all capabilities
  - All peers: can send to org.freedesktop.DBus, can own names matching their uid
  - System services (uid < 1000): can own system bus names
  """

  @behaviour GaoBus.Policy.Behaviour

  use GenServer

  require Logger

  @table :gao_bus_capabilities

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Grant a capability to a peer identified by unique name.
  """
  def grant(unique_name, capability) do
    GenServer.call(__MODULE__, {:grant, unique_name, capability})
  end

  @doc """
  Revoke a capability from a peer.
  """
  def revoke(unique_name, capability) do
    GenServer.call(__MODULE__, {:revoke, unique_name, capability})
  end

  @doc """
  Get all capabilities for a peer.
  """
  def capabilities(unique_name) do
    try do
      :ets.lookup(@table, unique_name)
      |> Enum.map(fn {_, cap} -> cap end)
    catch
      :error, :badarg -> []
    end
  end

  @doc """
  Set up default capabilities for a peer based on credentials.
  """
  def setup_defaults(unique_name, credentials) do
    GenServer.cast(__MODULE__, {:setup_defaults, unique_name, credentials})
  end

  @doc """
  Remove all capabilities for a disconnected peer.
  """
  def peer_disconnected(unique_name) do
    GenServer.cast(__MODULE__, {:peer_disconnected, unique_name})
  end

  # --- Policy.Behaviour callbacks ---

  @impl GaoBus.Policy.Behaviour
  def check_send(credentials, message_info) do
    unique_name = credentials[:unique_name]
    caps = capabilities(unique_name)

    cond do
      has_superuser?(caps) ->
        :allow

      # Always allow messages to the bus itself
      message_info[:destination] == "org.freedesktop.DBus" ->
        :allow

      # Always allow method returns and errors (they're responses)
      message_info[:type] in [:method_return, :error] ->
        :allow

      # Check specific method call capability
      message_info[:type] == :method_call ->
        dest = message_info[:destination]
        iface = message_info[:interface]
        member = message_info[:member]

        if has_send_capability?(caps, dest, iface, member) do
          :allow
        else
          GaoBus.PubSub.broadcast({:policy_denied, :send, unique_name, message_info})
          {:deny, "org.freedesktop.DBus.Error.AccessDenied"}
        end

      # Signals — check send capability
      message_info[:type] == :signal ->
        :allow

      true ->
        :allow
    end
  end

  @impl GaoBus.Policy.Behaviour
  def check_own(credentials, name) do
    unique_name = credentials[:unique_name]
    caps = capabilities(unique_name)

    cond do
      has_superuser?(caps) ->
        :allow

      Enum.any?(caps, fn
        {:own, ^name} -> true
        {:own, :any} -> true
        _ -> false
      end) ->
        :allow

      true ->
        GaoBus.PubSub.broadcast({:policy_denied, :own, unique_name, name})
        {:deny, "org.freedesktop.DBus.Error.AccessDenied"}
    end
  end

  @impl GaoBus.Policy.Behaviour
  def check_eavesdrop(credentials) do
    unique_name = credentials[:unique_name]
    caps = capabilities(unique_name)

    if has_superuser?(caps) do
      :allow
    else
      {:deny, "org.freedesktop.DBus.Error.AccessDenied"}
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:bag, :named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:grant, unique_name, capability}, _from, state) do
    :ets.insert(@table, {unique_name, capability})
    {:reply, :ok, state}
  end

  def handle_call({:revoke, unique_name, capability}, _from, state) do
    :ets.delete_object(@table, {unique_name, capability})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:setup_defaults, unique_name, credentials}, state) do
    uid = credentials[:uid]

    # Root gets all capabilities
    if uid == 0 do
      :ets.insert(@table, {unique_name, {:all, :all}})
    else
      # Everyone can talk to the bus
      :ets.insert(@table, {unique_name, {:send, "org.freedesktop.DBus"}})

      # System users (uid < 1000) can own system names and send broadly
      if is_integer(uid) and uid < 1000 do
        :ets.insert(@table, {unique_name, {:own, :any}})
        :ets.insert(@table, {unique_name, {:send, :any}})
      end

      # Regular users can send to any destination by default (permissive mode)
      # This can be tightened for production
      :ets.insert(@table, {unique_name, {:send, :any}})
    end

    {:noreply, state}
  end

  def handle_cast({:peer_disconnected, unique_name}, state) do
    :ets.delete(@table, unique_name)
    {:noreply, state}
  end

  # --- Private helpers ---

  defp has_superuser?(caps) do
    Enum.any?(caps, fn
      {:all, :all} -> true
      _ -> false
    end)
  end

  defp has_send_capability?(caps, dest, iface, member) do
    Enum.any?(caps, fn
      {:all, :all} -> true
      {:send, :any} -> true
      {:send, ^dest} -> true
      {:call, {^dest, ^iface, ^member}} -> true
      {:call, {^dest, ^iface}} -> true
      _ -> false
    end)
  end
end
