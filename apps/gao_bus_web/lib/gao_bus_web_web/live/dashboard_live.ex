defmodule GaoBusWebWeb.DashboardLive do
  use GaoBusWebWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      GaoBus.PubSub.subscribe()
      :timer.send_interval(1_000, self(), :tick)
    end

    names = safe_list_names()
    peers = count_peers(names)

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       peer_count: peers,
       names: names,
       message_count: 0,
       messages_per_second: 0,
       msg_window: [],
       bus_start_time: System.monotonic_time(:second)
     )}
  end

  @impl true
  def handle_info({:message_routed, _msg}, socket) do
    window = [System.monotonic_time(:second) | Enum.take(socket.assigns.msg_window, 99)]

    {:noreply,
     assign(socket,
       message_count: socket.assigns.message_count + 1,
       msg_window: window
     )}
  end

  def handle_info({:peer_connected, _name, _pid}, socket) do
    {:noreply, assign(socket, peer_count: socket.assigns.peer_count + 1)}
  end

  def handle_info({:peer_disconnected, _name, _pid}, socket) do
    {:noreply, assign(socket, peer_count: max(0, socket.assigns.peer_count - 1))}
  end

  def handle_info({:name_acquired, _name, _owner}, socket) do
    {:noreply, assign(socket, names: safe_list_names())}
  end

  def handle_info({:name_released, _name, _owner}, socket) do
    {:noreply, assign(socket, names: safe_list_names())}
  end

  def handle_info(:tick, socket) do
    now = System.monotonic_time(:second)
    recent = Enum.count(socket.assigns.msg_window, fn t -> now - t < 1 end)

    {:noreply, assign(socket, messages_per_second: recent)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Bus Dashboard</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <.stat_card title="Connected Peers" value={@peer_count} icon="hero-users" />
        <.stat_card title="Messages/sec" value={@messages_per_second} icon="hero-envelope" />
        <.stat_card title="Total Messages" value={@message_count} icon="hero-chart-bar" />
        <.stat_card title="Uptime" value={format_uptime(@bus_start_time)} icon="hero-clock" />
      </div>

      <div class="card bg-base-200 p-6">
        <h2 class="text-lg font-semibold mb-4">Name Registry</h2>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Name</th>
                <th>Type</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={name <- @names}>
                <td class="font-mono text-sm">{name}</td>
                <td>
                  <span :if={String.starts_with?(name, ":")} class="badge badge-info badge-sm">unique</span>
                  <span :if={!String.starts_with?(name, ":")} class="badge badge-success badge-sm">well-known</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200 p-4">
      <div class="flex items-center gap-3">
        <div class="rounded-lg bg-primary/10 p-2">
          <.icon name={@icon} class="size-6 text-primary" />
        </div>
        <div>
          <div class="text-sm opacity-70">{@title}</div>
          <div class="text-2xl font-bold">{@value}</div>
        </div>
      </div>
    </div>
    """
  end

  defp format_uptime(start_time) do
    elapsed = System.monotonic_time(:second) - start_time
    hours = div(elapsed, 3600)
    minutes = div(rem(elapsed, 3600), 60)
    seconds = rem(elapsed, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{seconds}s"
      true -> "#{seconds}s"
    end
  end

  defp safe_list_names do
    if Process.whereis(GaoBus.NameRegistry) do
      GaoBus.NameRegistry.list_names()
    else
      []
    end
  end

  defp count_peers(names) do
    Enum.count(names, &String.starts_with?(&1, ":"))
  end
end
