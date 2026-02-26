defmodule GaoBusWebWeb.IntrospectLive do
  use GaoBusWebWeb, :live_view

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
       introspection: nil
     )}
  end

  @impl true
  def handle_info({:name_acquired, _name, _owner}, socket) do
    {:noreply, assign(socket, names: safe_list_names())}
  end

  def handle_info({:name_released, _name, _owner}, socket) do
    {:noreply, assign(socket, names: safe_list_names())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, selected_name: name, introspection: nil)}
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
          <div :if={@selected_name} class="space-y-4">
            <h2 class="font-semibold">
              <span class="font-mono">{@selected_name}</span>
            </h2>

            <div class="text-sm opacity-70">
              <p>
                Introspection requires sending a method call to the service.
                This will be available once the bus supports org.freedesktop.DBus.Introspectable.
              </p>
            </div>

            <div class="card bg-base-300 p-3">
              <h3 class="text-sm font-semibold mb-2">Standard Interfaces</h3>
              <ul class="text-xs font-mono space-y-1 opacity-80">
                <li>org.freedesktop.DBus.Introspectable</li>
                <li>org.freedesktop.DBus.Peer</li>
                <li>org.freedesktop.DBus.Properties</li>
              </ul>
            </div>
          </div>

          <div :if={!@selected_name} class="text-center py-12 opacity-50">
            <.icon name="hero-cursor-arrow-rays" class="size-12 mx-auto mb-2" />
            <p>Select a service to view its interfaces</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp safe_list_names do
    if Process.whereis(GaoBus.NameRegistry) do
      GaoBus.NameRegistry.list_names()
    else
      []
    end
  end
end
