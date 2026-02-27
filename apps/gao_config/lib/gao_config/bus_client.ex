defmodule GaoConfig.BusClient do
  @moduledoc """
  Manages the D-Bus connection for gao_config.

  Connects to gao_bus, calls Hello(), registers org.gaoos.Config1,
  and dispatches incoming method_call messages to the DBusInterface.
  """

  use GenServer

  alias ExDBus.{Connection, Message, Proxy}

  require Logger

  @service_name "org.gaoos.Config1"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the connection pid if connected.
  """
  def connection do
    GenServer.call(__MODULE__, :get_connection)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    address = Keyword.get(opts, :address, "unix:path=/tmp/gao_bus_socket")
    send(self(), {:connect, address})
    {:ok, %{address: address, connection: nil, unique_name: nil}}
  end

  @impl true
  def handle_info({:connect, address}, state) do
    case Connection.start_link(
           address: address,
           auth_mod: ExDBus.Auth.Anonymous,
           owner: self()
         ) do
      {:ok, conn} ->
        {:noreply, %{state | connection: conn}}

      {:error, reason} ->
        Logger.warning("GaoConfig.BusClient: failed to connect: #{inspect(reason)}")
        # Retry after delay
        Process.send_after(self(), {:connect, state.address}, 1_000)
        {:noreply, state}
    end
  end

  def handle_info({:ex_dbus, {:connected, _guid}}, state) do
    Logger.debug("GaoConfig.BusClient: connected to bus")
    # Call Hello
    bus = Proxy.new(state.connection, "org.freedesktop.DBus", "/org/freedesktop/DBus")

    case Proxy.call(bus, "org.freedesktop.DBus", "Hello") do
      {:ok, %Message{body: [unique_name]}} ->
        Logger.debug("GaoConfig.BusClient: assigned #{unique_name}")

        # Request well-known name
        case Proxy.call(bus, "org.freedesktop.DBus", "RequestName",
               signature: "su",
               body: [@service_name, 0]
             ) do
          {:ok, %Message{body: [1]}} ->
            Logger.info("GaoConfig.BusClient: registered #{@service_name}")
            {:noreply, %{state | unique_name: unique_name}}

          {:ok, %Message{body: [code]}} ->
            Logger.warning("GaoConfig.BusClient: RequestName returned #{code}")
            {:noreply, %{state | unique_name: unique_name}}

          {:error, reason} ->
            Logger.error("GaoConfig.BusClient: RequestName failed: #{inspect(reason)}")
            {:noreply, %{state | unique_name: unique_name}}
        end

      {:error, reason} ->
        Logger.error("GaoConfig.BusClient: Hello failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:ex_dbus, {:message, %Message{type: :method_call} = msg}}, state) do
    # Dispatch to DBusInterface via Object behaviour
    result = ExDBus.Object.dispatch(msg, GaoConfig.DBusInterface)

    case result do
      {:ok, reply} ->
        Connection.cast(state.connection, reply)

      {:error, error} ->
        Connection.cast(state.connection, error)
    end

    {:noreply, state}
  end

  def handle_info({:ex_dbus, {:message, %Message{type: :signal}}}, state) do
    # Ignore signals for now
    {:noreply, state}
  end

  def handle_info({:ex_dbus, :disconnected}, state) do
    Logger.warning("GaoConfig.BusClient: disconnected from bus, reconnecting...")
    Process.send_after(self(), {:connect, state.address}, 1_000)
    {:noreply, %{state | connection: nil, unique_name: nil}}
  end

  def handle_info({:ex_dbus, {:connection_error, reason}}, state) do
    Logger.warning("GaoConfig.BusClient: connection error: #{inspect(reason)}")
    Process.send_after(self(), {:connect, state.address}, 1_000)
    {:noreply, %{state | connection: nil, unique_name: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_connection, _from, state) do
    {:reply, state.connection, state}
  end
end
