defmodule GaoBus.Router do
  @moduledoc """
  Routes D-Bus messages between peers.

  - method_call → destination peer (or bus itself for org.freedesktop.DBus)
  - method_return/error → back to caller by reply_serial
  - signal → broadcast to all peers (match rules come later)
  """

  use GenServer

  alias ExDBus.Message

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Route a message from a peer.
  """
  def route(message, from_peer_pid) do
    GenServer.cast(__MODULE__, {:route, message, from_peer_pid})
  end

  @doc """
  Emit a signal from the bus itself (e.g., NameOwnerChanged).
  """
  def emit_signal(path, interface, member, signature, body) do
    GenServer.cast(__MODULE__, {:emit_signal, path, interface, member, signature, body})
  end

  @doc """
  Register a peer for signal broadcasting.
  """
  def register_peer(peer_pid, unique_name) do
    GenServer.cast(__MODULE__, {:register_peer, peer_pid, unique_name})
  end

  @doc """
  Unregister a peer.
  """
  def unregister_peer(peer_pid) do
    GenServer.cast(__MODULE__, {:unregister_peer, peer_pid})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # peers: %{pid => unique_name}
    {:ok, %{peers: %{}, next_serial: 1}}
  end

  @impl true
  def handle_cast({:route, message, from_peer_pid}, state) do
    GaoBus.PubSub.broadcast({:message_routed, message})

    case check_policy(message, from_peer_pid) do
      :allow ->
        state = do_route(message, from_peer_pid, state)
        {:noreply, state}

      {:deny, error_name} ->
        # Send access denied error back to caller
        if message.type == :method_call do
          {serial, state} = next_serial(state)

          error =
            Message.error(error_name, message.serial,
              serial: serial,
              destination: message.sender,
              sender: "org.freedesktop.DBus",
              signature: "s",
              body: ["Rejected send message"]
            )

          send(from_peer_pid, {:send_message, error})
          {:noreply, state}
        else
          {:noreply, state}
        end
    end
  end

  def handle_cast({:emit_signal, path, interface, member, signature, body}, state) do
    {serial, state} = next_serial(state)

    signal = %Message{
      type: :signal,
      serial: serial,
      path: path,
      interface: interface,
      member: member,
      sender: "org.freedesktop.DBus",
      signature: signature,
      body: body
    }

    broadcast_signal(signal, state)
    {:noreply, state}
  end

  def handle_cast({:register_peer, peer_pid, unique_name}, state) do
    Process.monitor(peer_pid)
    {:noreply, put_in(state.peers[peer_pid], unique_name)}
  end

  def handle_cast({:unregister_peer, peer_pid}, state) do
    {:noreply, %{state | peers: Map.delete(state.peers, peer_pid)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, peer_pid, _reason}, state) do
    {:noreply, %{state | peers: Map.delete(state.peers, peer_pid)}}
  end

  # --- Routing logic ---

  defp do_route(%Message{destination: "org.freedesktop.DBus"} = msg, from_peer_pid, state) do
    {reply, state} = GaoBus.BusInterface.handle_message(msg, from_peer_pid, state)

    if reply do
      send(from_peer_pid, {:send_message, reply})
    end

    state
  end

  defp do_route(%Message{type: :method_call, destination: dest} = msg, _from_peer_pid, state)
       when is_binary(dest) do
    case GaoBus.NameRegistry.resolve(dest) do
      {:ok, target_pid} ->
        send(target_pid, {:send_message, msg})
        state

      {:error, :name_not_found} ->
        # Try cluster routing if enabled
        case try_cluster_route(msg) do
          {:ok, :forwarded} ->
            state

          _ ->
            # Send error back to caller
            {serial, state} = next_serial(state)

            error =
              Message.error(
                "org.freedesktop.DBus.Error.ServiceUnknown",
                msg.serial,
                serial: serial,
                destination: msg.sender,
                signature: "s",
                body: ["The name #{dest} was not provided by any .service files"]
              )

            case GaoBus.NameRegistry.resolve(msg.sender) do
              {:ok, sender_pid} -> send(sender_pid, {:send_message, error})
              _ -> :ok
            end

            state
        end

      {:bus, _} ->
        # This shouldn't happen (already handled above), but just in case
        state
    end
  end

  defp do_route(%Message{type: :method_call, destination: nil} = msg, from_peer_pid, state) do
    # No destination — treat as bus message
    {reply, state} = GaoBus.BusInterface.handle_message(msg, from_peer_pid, state)
    if reply, do: send(from_peer_pid, {:send_message, reply})
    state
  end

  defp do_route(%Message{type: type, destination: dest} = msg, _from_peer_pid, state)
       when type in [:method_return, :error] and is_binary(dest) do
    case GaoBus.NameRegistry.resolve(dest) do
      {:ok, target_pid} -> send(target_pid, {:send_message, msg})
      _ -> Logger.debug("GaoBus.Router: cannot route #{type} to #{dest}")
    end

    state
  end

  defp do_route(%Message{type: :signal} = msg, _from_peer_pid, state) do
    broadcast_signal(msg, state)
    state
  end

  defp do_route(msg, _from_peer_pid, state) do
    Logger.debug("GaoBus.Router: unhandled message: #{inspect(msg.type)}")
    state
  end

  defp broadcast_signal(signal, state) do
    # Get peers that have matching match rules
    matching_pids = GaoBus.MatchRules.matching_peers(signal) |> MapSet.new()

    for {pid, _name} <- state.peers do
      # Send to peers that either have a matching rule or have no rules (backward compat)
      if MapSet.member?(matching_pids, pid) or not has_match_rules?(pid) do
        send(pid, {:send_message, signal})
      end
    end
  end

  defp has_match_rules?(pid) do
    try do
      :ets.match(:gao_bus_match_rules, {pid, :_, :_, :_}) != []
    catch
      :error, :badarg -> false
    end
  end

  defp check_policy(message, from_peer_pid) do
    if Process.whereis(GaoBus.Policy.Capability) do
      credentials =
        try do
          GaoBus.Peer.get_credentials(from_peer_pid) || %{}
        catch
          :exit, _ -> %{}
        end

      message_info = %{
        type: message.type,
        sender: message.sender,
        destination: message.destination,
        interface: message.interface,
        member: message.member,
        path: message.path
      }

      GaoBus.Policy.Capability.check_send(credentials, message_info)
    else
      :allow
    end
  end

  defp try_cluster_route(msg) do
    if Process.whereis(GaoBus.Cluster) do
      GaoBus.Cluster.route_remote(msg)
    else
      {:error, :not_found}
    end
  end

  defp next_serial(state) do
    {state.next_serial, %{state | next_serial: state.next_serial + 1}}
  end
end
