defmodule GaoBusWebWeb.MessagesLive do
  use GaoBusWebWeb, :live_view

  @max_messages 1000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      GaoBus.PubSub.subscribe()
    end

    {:ok,
     socket
     |> assign(
       page_title: "Messages",
       paused: false,
       selected_id: nil,
       filter_type: "",
       filter_sender: "",
       filter_dest: "",
       filter_interface: "",
       filter_member: "",
       msg_counter: 0
     )
     |> stream(:messages, [])}
  end

  @impl true
  def handle_info({:message_routed, msg}, socket) do
    if socket.assigns.paused do
      {:noreply, socket}
    else
      if matches_filter?(msg, socket.assigns) do
        counter = socket.assigns.msg_counter + 1

        entry = %{
          id: "msg-#{counter}",
          timestamp: DateTime.utc_now(),
          type: msg.type,
          sender: msg.sender || "",
          destination: msg.destination || "",
          interface: msg.interface || "",
          member: msg.member || "",
          path: msg.path || "",
          serial: msg.serial,
          signature: msg.signature,
          body: msg.body,
          error_name: msg.error_name
        }

        socket =
          socket
          |> assign(msg_counter: counter)
          |> stream_insert(:messages, entry, at: 0, limit: @max_messages)

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    {:noreply, assign(socket, paused: !socket.assigns.paused)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, stream(socket, :messages, [], reset: true)}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     assign(socket,
       filter_type: params["type"] || "",
       filter_sender: params["sender"] || "",
       filter_dest: params["dest"] || "",
       filter_interface: params["interface"] || "",
       filter_member: params["member"] || ""
     )}
  end

  def handle_event("select", %{"id" => id}, socket) do
    selected = if socket.assigns.selected_id == id, do: nil, else: id
    {:noreply, assign(socket, selected_id: selected)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Messages</h1>
        <div class="flex gap-2">
          <button class="btn btn-sm" phx-click="toggle_pause">
            <.icon name={if @paused, do: "hero-play", else: "hero-pause"} class="size-4" />
            {if @paused, do: "Resume", else: "Pause"}
          </button>
          <button class="btn btn-sm btn-ghost" phx-click="clear">Clear</button>
        </div>
      </div>

      <form phx-change="filter" class="card bg-base-200 p-4">
        <div class="grid grid-cols-2 md:grid-cols-5 gap-2">
          <select name="type" class="select select-bordered select-sm">
            <option value="">All Types</option>
            <option value="method_call" selected={@filter_type == "method_call"}>method_call</option>
            <option value="method_return" selected={@filter_type == "method_return"}>method_return</option>
            <option value="error" selected={@filter_type == "error"}>error</option>
            <option value="signal" selected={@filter_type == "signal"}>signal</option>
          </select>
          <input name="sender" value={@filter_sender} placeholder="Sender" class="input input-bordered input-sm" />
          <input name="dest" value={@filter_dest} placeholder="Destination" class="input input-bordered input-sm" />
          <input name="interface" value={@filter_interface} placeholder="Interface" class="input input-bordered input-sm" />
          <input name="member" value={@filter_member} placeholder="Member" class="input input-bordered input-sm" />
        </div>
      </form>

      <div class="overflow-x-auto">
        <table class="table table-xs table-zebra">
          <thead>
            <tr>
              <th>Time</th>
              <th>Type</th>
              <th>Sender</th>
              <th>Dest</th>
              <th>Interface</th>
              <th>Member</th>
              <th>Serial</th>
            </tr>
          </thead>
          <tbody id="messages" phx-update="stream">
            <tr
              :for={{dom_id, msg} <- @streams.messages}
              id={dom_id}
              class={"cursor-pointer hover:bg-base-300 #{if @selected_id == dom_id, do: "bg-base-300"}"}
              phx-click="select"
              phx-value-id={dom_id}
            >
              <td class="font-mono text-xs">{format_time(msg.timestamp)}</td>
              <td><.type_badge type={msg.type} /></td>
              <td class="font-mono text-xs max-w-32 truncate">{msg.sender}</td>
              <td class="font-mono text-xs max-w-32 truncate">{msg.destination}</td>
              <td class="font-mono text-xs max-w-40 truncate">{msg.interface}</td>
              <td class="font-mono text-xs">{msg.member}</td>
              <td class="font-mono text-xs">{msg.serial}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@selected_id} class="card bg-base-200 p-4">
        <h3 class="font-semibold mb-2">Message Details</h3>
        <p class="text-sm opacity-70">Click a message row to see its full body and signature.</p>
      </div>
    </div>
    """
  end

  defp type_badge(assigns) do
    color =
      case assigns.type do
        :method_call -> "badge-primary"
        :method_return -> "badge-success"
        :error -> "badge-error"
        :signal -> "badge-warning"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge badge-xs #{@color}"}>{@type}</span>
    """
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S.") <>
      String.pad_leading("#{dt.microsecond |> elem(0) |> div(1000)}", 3, "0")
  end

  defp matches_filter?(msg, assigns) do
    (assigns.filter_type == "" or to_string(msg.type) == assigns.filter_type) and
      (assigns.filter_sender == "" or contains?(msg.sender, assigns.filter_sender)) and
      (assigns.filter_dest == "" or contains?(msg.destination, assigns.filter_dest)) and
      (assigns.filter_interface == "" or contains?(msg.interface, assigns.filter_interface)) and
      (assigns.filter_member == "" or contains?(msg.member, assigns.filter_member))
  end

  defp contains?(nil, _filter), do: false
  defp contains?(value, filter), do: String.contains?(value, filter)
end
