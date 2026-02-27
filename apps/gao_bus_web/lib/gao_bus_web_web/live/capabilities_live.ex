defmodule GaoBusWebWeb.CapabilitiesLive do
  use GaoBusWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      GaoBus.PubSub.subscribe()
    end

    {:ok,
     assign(socket,
       page_title: "Capabilities",
       peers: load_peers(),
       denial_log: [],
       selected_peer: nil
     )}
  end

  @impl true
  def handle_info({:policy_denied, action, unique_name, info}, socket) do
    entry = %{
      time: DateTime.utc_now(),
      action: action,
      peer: unique_name,
      detail: format_denial(action, info)
    }

    log = Enum.take([entry | socket.assigns.denial_log], 100)
    {:noreply, assign(socket, denial_log: log)}
  end

  def handle_info({:peer_connected, _name, _pid}, socket) do
    {:noreply, assign(socket, peers: load_peers())}
  end

  def handle_info({:peer_disconnected, _name, _pid}, socket) do
    {:noreply, assign(socket, peers: load_peers())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_peer", %{"peer" => peer}, socket) do
    {:noreply, assign(socket, selected_peer: peer)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, peers: load_peers())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Capabilities</h1>
        <button phx-click="refresh" class="btn btn-sm btn-outline">Refresh</button>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%!-- Peer List --%>
        <div class="card bg-base-200 p-6">
          <h2 class="text-lg font-semibold mb-4">Peers</h2>
          <div class="space-y-1">
            <button
              :for={{peer, caps} <- @peers}
              phx-click="select_peer"
              phx-value-peer={peer}
              class={"w-full text-left p-2 rounded font-mono text-sm hover:bg-base-300 #{if @selected_peer == peer, do: "bg-primary/20 font-bold", else: ""}"}
            >
              <span>{peer}</span>
              <span class="badge badge-sm ml-2">{length(caps)}</span>
            </button>
            <p :if={@peers == []} class="text-sm opacity-50">No peers connected</p>
          </div>
        </div>

        <%!-- Capabilities Detail --%>
        <div class="card bg-base-200 p-6">
          <h2 class="text-lg font-semibold mb-4">
            {if @selected_peer, do: "Capabilities for #{@selected_peer}", else: "Select a peer"}
          </h2>
          <div :if={@selected_peer}>
            <% caps = peer_caps(@peers, @selected_peer) %>
            <table :if={caps != []} class="table table-zebra table-sm">
              <thead>
                <tr>
                  <th>Scope</th>
                  <th>Target</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={cap <- caps}>
                  <td>
                    <span class={"badge badge-sm #{cap_badge(cap)}"}>{cap_scope(cap)}</span>
                  </td>
                  <td class="font-mono text-sm">{cap_target(cap)}</td>
                </tr>
              </tbody>
            </table>
            <p :if={caps == []} class="text-sm opacity-50">No capabilities</p>
          </div>
        </div>
      </div>

      <%!-- Denial Audit Log --%>
      <div class="card bg-base-200 p-6">
        <h2 class="text-lg font-semibold mb-4">
          Access Denial Log
          <span :if={@denial_log != []} class="badge badge-error badge-sm ml-2">
            {length(@denial_log)}
          </span>
        </h2>
        <div class="overflow-x-auto">
          <table :if={@denial_log != []} class="table table-zebra table-sm">
            <thead>
              <tr>
                <th>Time</th>
                <th>Peer</th>
                <th>Action</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @denial_log}>
                <td class="text-xs opacity-70">{Calendar.strftime(entry.time, "%H:%M:%S")}</td>
                <td class="font-mono text-sm">{entry.peer}</td>
                <td><span class="badge badge-error badge-sm">{entry.action}</span></td>
                <td class="text-sm">{entry.detail}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@denial_log == []} class="text-sm opacity-50">No access denials recorded</p>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp load_peers do
    if Process.whereis(GaoBus.Policy.Capability) do
      names = safe_list_names()

      names
      |> Enum.filter(&String.starts_with?(&1, ":"))
      |> Enum.map(fn name -> {name, GaoBus.Policy.Capability.capabilities(name)} end)
      |> Enum.sort_by(fn {name, _} -> name end)
    else
      []
    end
  end

  defp safe_list_names do
    if Process.whereis(GaoBus.NameRegistry) do
      GaoBus.NameRegistry.list_names()
    else
      []
    end
  end

  defp peer_caps(peers, selected) do
    case List.keyfind(peers, selected, 0) do
      {_, caps} -> caps
      nil -> []
    end
  end

  defp cap_scope({scope, _}), do: scope
  defp cap_scope(_), do: "?"

  defp cap_target({:all, :all}), do: "*"
  defp cap_target({_scope, :any}), do: "any"
  defp cap_target({_scope, {dest, iface, method}}), do: "#{dest} → #{iface}.#{method}"
  defp cap_target({_scope, {dest, iface}}), do: "#{dest} → #{iface}.*"
  defp cap_target({_scope, target}) when is_binary(target), do: target
  defp cap_target(_), do: "?"

  defp cap_badge({:all, :all}), do: "badge-warning"
  defp cap_badge({:send, _}), do: "badge-info"
  defp cap_badge({:own, _}), do: "badge-success"
  defp cap_badge({:call, _}), do: "badge-primary"
  defp cap_badge({:receive, _}), do: "badge-secondary"
  defp cap_badge(_), do: ""

  defp format_denial(:send, info) do
    dest = info[:destination] || "?"
    iface = info[:interface] || "?"
    member = info[:member] || "?"
    "send → #{dest} #{iface}.#{member}"
  end

  defp format_denial(:own, name) when is_binary(name) do
    "own #{name}"
  end

  defp format_denial(action, _info) do
    "#{action}"
  end
end
