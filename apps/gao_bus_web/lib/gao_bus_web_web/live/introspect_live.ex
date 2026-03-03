defmodule GaoBusWebWeb.IntrospectLive do
  use GaoBusWebWeb, :live_view

  alias ExDBus.Message

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      GaoBus.PubSub.subscribe()
    end

    names = safe_list_names()

    {:ok,
     assign(socket,
       page_title: "Introspect",
       names: names,
       selected_name: nil,
       interfaces: [],
       children: [],
       loading: false,
       error: nil
     )}
  end

  @impl true
  def handle_info({:name_acquired, _name, _owner}, socket) do
    {:noreply, assign(socket, names: safe_list_names())}
  end

  def handle_info({:name_released, _name, _owner}, socket) do
    {:noreply, assign(socket, names: safe_list_names())}
  end

  def handle_info({:introspect_result, name, {:ok, interfaces, children}}, socket) do
    if socket.assigns.selected_name == name do
      {:noreply,
       assign(socket,
         interfaces: interfaces,
         children: children,
         loading: false,
         error: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:introspect_result, name, {:error, reason}}, socket) do
    if socket.assigns.selected_name == name do
      {:noreply,
       assign(socket,
         interfaces: [],
         children: [],
         loading: false,
         error: "Introspection failed: #{inspect(reason)}"
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_name", %{"name" => name}, socket) do
    socket = assign(socket, selected_name: name, interfaces: [], children: [], loading: true, error: nil)
    do_introspect(name, "/")
    {:noreply, socket}
  end

  def handle_event("introspect_path", %{"name" => name, "path" => path}, socket) do
    socket = assign(socket, loading: true, error: nil)
    do_introspect(name, path)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Introspect</h1>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold mb-3">Registered Services</h2>
          <ul class="space-y-1">
            <li :for={name <- @names}>
              <button
                class={"btn btn-ghost btn-sm w-full justify-start font-mono text-xs #{if @selected_name == name, do: "btn-active"}"}
                phx-click="select_name"
                phx-value-name={name}
              >
                <.icon
                  name={if String.starts_with?(name, ":"), do: "hero-user", else: "hero-cube"}
                  class="size-3"
                />
                {name}
              </button>
            </li>
          </ul>
        </div>

        <div class="md:col-span-2 card bg-base-200 p-4">
          <div :if={@loading} class="text-center py-12">
            <span class="loading loading-spinner loading-md"></span>
            <p class="mt-2 text-sm opacity-70">Introspecting...</p>
          </div>

          <div :if={@error} class="alert alert-error">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>{@error}</span>
          </div>

          <div :if={@selected_name && !@loading && !@error} class="space-y-4">
            <h2 class="font-semibold">
              <span class="font-mono">{@selected_name}</span>
            </h2>

            <div :for={iface <- @interfaces} class="card bg-base-300 p-3 space-y-2">
              <h3 class="text-sm font-semibold font-mono">{iface.name}</h3>

              <div :if={iface.methods != []} class="space-y-1">
                <h4 class="text-xs font-semibold opacity-70">Methods</h4>
                <div :for={method <- iface.methods} class="text-xs font-mono pl-2">
                  <span class="text-primary">{method.name}</span>(<%= for arg <- (method.args || []), arg.direction == :in do %><span class="opacity-70">{arg.name}:{arg.type}</span> <% end %>) ->
                  <%= for arg <- (method.args || []), arg.direction == :out do %><span class="text-success">{arg.type}</span><% end %>
                </div>
              </div>

              <div :if={iface.signals != []} class="space-y-1">
                <h4 class="text-xs font-semibold opacity-70">Signals</h4>
                <div :for={signal <- iface.signals} class="text-xs font-mono pl-2">
                  <span class="text-warning">{signal.name}</span>(<%= for arg <- (signal.args || []) do %><span class="opacity-70">{arg.name}:{arg.type}</span> <% end %>)
                </div>
              </div>

              <div :if={iface.properties != []} class="space-y-1">
                <h4 class="text-xs font-semibold opacity-70">Properties</h4>
                <div :for={prop <- iface.properties} class="text-xs font-mono pl-2">
                  <span class="text-info">{prop.name}</span> : {prop.type} [{prop.access}]
                </div>
              </div>
            </div>

            <div :if={@children != []} class="card bg-base-300 p-3">
              <h3 class="text-sm font-semibold mb-2">Child Nodes</h3>
              <div :for={child <- @children} class="text-xs font-mono">
                <button
                  class="btn btn-ghost btn-xs font-mono"
                  phx-click="introspect_path"
                  phx-value-name={@selected_name}
                  phx-value-path={child}
                >
                  {child}
                </button>
              </div>
            </div>

            <div :if={@interfaces == [] && @children == []} class="text-sm opacity-70">
              <p>No interfaces or children found at this path.</p>
            </div>
          </div>

          <div :if={!@selected_name && !@loading} class="text-center py-12 opacity-50">
            <.icon name="hero-cursor-arrow-rays" class="size-12 mx-auto mb-2" />
            <p>Select a service to view its interfaces</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp do_introspect(name, path) do
    caller = self()

    Task.start(fn ->
      result = introspect_via_bus(name, path)
      send(caller, {:introspect_result, name, result})
    end)
  end

  defp introspect_via_bus(name, path) do
    msg =
      Message.method_call(
        path,
        "org.freedesktop.DBus.Introspectable",
        "Introspect",
        destination: name,
        sender: "org.freedesktop.DBus"
      )

    case GaoBus.NameRegistry.resolve(name) do
      {:ok, peer_pid} ->
        send(peer_pid, {:send_message, %{msg | serial: :erlang.unique_integer([:positive])}})
        :timer.sleep(100)
        {:ok, [], []}

      {:bus, _pid} ->
        introspect_bus(msg)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp introspect_bus(msg) do
    state = %{peers: %{}, next_serial: 1}
    {reply, _state} = GaoBus.BusInterface.handle_message(msg, self(), state)

    if reply && reply.type == :method_return do
      [xml] = reply.body

      case ExDBus.Introspection.from_xml(xml) do
        {:ok, _path, interfaces, children} -> {:ok, interfaces, children}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_reply}
    end
  end

  defp safe_list_names do
    if Process.whereis(GaoBus.NameRegistry) do
      GaoBus.NameRegistry.list_names()
    else
      []
    end
  end
end
