defmodule GaoBusWebWeb.CallLive do
  use GaoBusWebWeb, :live_view

  alias ExDBus.Message

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      GaoBus.PubSub.subscribe()
    end

    names = safe_list_names() |> Enum.reject(&String.starts_with?(&1, ":"))

    {:ok,
     assign(socket,
       page_title: "Call",
       names: names,
       service: "",
       object_path: "/",
       interface: "",
       method: "",
       signature: "",
       args: "",
       result: nil,
       error: nil,
       calling: false
     )}
  end

  @impl true
  def handle_info({:name_acquired, _name, _owner}, socket) do
    names = safe_list_names() |> Enum.reject(&String.starts_with?(&1, ":"))
    {:noreply, assign(socket, names: names)}
  end

  def handle_info({:name_released, _name, _owner}, socket) do
    names = safe_list_names() |> Enum.reject(&String.starts_with?(&1, ":"))
    {:noreply, assign(socket, names: names)}
  end

  def handle_info({:call_result, {:ok, reply}}, socket) do
    result_text =
      case reply.type do
        :method_return ->
          "Reply (#{reply.signature || ""}): #{inspect(reply.body, pretty: true)}"

        :error ->
          "D-Bus Error: #{reply.error_name}\n#{inspect(reply.body, pretty: true)}"

        _ ->
          inspect(reply, pretty: true)
      end

    {:noreply, assign(socket, result: result_text, error: nil, calling: false)}
  end

  def handle_info({:call_result, {:error, reason}}, socket) do
    {:noreply, assign(socket, error: "Call failed: #{inspect(reason)}", result: nil, calling: false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("update_form", params, socket) do
    {:noreply,
     assign(socket,
       service: params["service"] || socket.assigns.service,
       object_path: params["object_path"] || socket.assigns.object_path,
       interface: params["interface"] || socket.assigns.interface,
       method: params["method"] || socket.assigns.method,
       signature: params["signature"] || socket.assigns.signature,
       args: params["args"] || socket.assigns.args
     )}
  end

  def handle_event("call", _params, socket) do
    assigns = socket.assigns

    if assigns.service == "" or assigns.method == "" do
      {:noreply, assign(socket, error: "Service and Method are required", result: nil)}
    else
      socket = assign(socket, calling: true, error: nil, result: nil)

      # Build the method call
      opts = [destination: assigns.service]

      {opts, arg_error} =
        if assigns.signature != "" do
          case parse_args(assigns.args, assigns.signature) do
            {:ok, body} ->
              {Keyword.merge(opts, signature: assigns.signature, body: body), nil}

            {:error, reason} ->
              {opts, reason}
          end
        else
          {opts, nil}
        end

      if arg_error do
        {:noreply, assign(socket, error: "Argument error: #{inspect(arg_error)}", calling: false)}
      else
        iface = if assigns.interface != "", do: assigns.interface, else: nil

        msg =
          Message.method_call(
            assigns.object_path,
            iface,
            assigns.method,
            opts
          )

        caller = self()

        Task.start(fn ->
          result = route_call(msg)
          send(caller, {:call_result, result})
        end)

        {:noreply, socket}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Method Call</h1>

      <form phx-change="update_form" phx-submit="call" class="card bg-base-200 p-6 space-y-4">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div class="form-control">
            <label class="label"><span class="label-text">Service</span></label>
            <select name="service" class="select select-bordered" value={@service}>
              <option value="">Select service...</option>
              <option :for={name <- @names} value={name} selected={@service == name}>{name}</option>
            </select>
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Object Path</span></label>
            <input name="object_path" value={@object_path} class="input input-bordered font-mono" />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Interface</span></label>
            <input name="interface" value={@interface} class="input input-bordered font-mono"
                   placeholder="org.freedesktop.DBus" />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Method</span></label>
            <input name="method" value={@method} class="input input-bordered font-mono"
                   placeholder="ListNames" />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Signature</span></label>
            <input name="signature" value={@signature} class="input input-bordered font-mono"
                   placeholder="s (leave empty for no args)" />
          </div>

          <div class="form-control">
            <label class="label"><span class="label-text">Arguments (JSON)</span></label>
            <input name="args" value={@args} class="input input-bordered font-mono"
                   placeholder='["hello", 42]' />
          </div>
        </div>

        <button type="submit" class={"btn btn-primary #{if @calling, do: "loading"}"} disabled={@calling}>
          <.icon name="hero-play" class="size-4" />
          Invoke
        </button>
      </form>

      <div :if={@result} class="card bg-success/10 border border-success p-4">
        <h3 class="font-semibold text-success mb-2">Result</h3>
        <pre class="font-mono text-sm whitespace-pre-wrap">{@result}</pre>
      </div>

      <div :if={@error} class="card bg-error/10 border border-error p-4">
        <h3 class="font-semibold text-error mb-2">Error</h3>
        <pre class="font-mono text-sm whitespace-pre-wrap">{@error}</pre>
      </div>
    </div>
    """
  end

  defp route_call(msg) do
    # For bus-addressed calls, handle inline via BusInterface
    if msg.destination == "org.freedesktop.DBus" do
      state = %{peers: %{}, next_serial: 1}
      stamped = %{msg | sender: "web-monitor", serial: :erlang.unique_integer([:positive])}

      case GaoBus.BusInterface.handle_message(stamped, self(), state) do
        {nil, _state} -> {:error, :no_reply}
        {reply, _state} -> {:ok, reply}
      end
    else
      # For other services, resolve and send through the router
      case GaoBus.NameRegistry.resolve(msg.destination) do
        {:ok, _peer_pid} ->
          # Route through the bus — send as a method call, the router handles delivery
          stamped = %{msg | sender: "web-monitor", serial: :erlang.unique_integer([:positive])}
          GaoBus.Router.route(stamped, self())

          # Wait for the reply to come back
          receive do
            {:send_message, %{type: type} = reply} when type in [:method_return, :error] ->
              {:ok, reply}
          after
            5_000 -> {:error, :timeout}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_args("", _signature), do: {:ok, []}

  defp parse_args(args_str, _signature) do
    case Jason.decode(args_str) do
      {:ok, args} when is_list(args) -> {:ok, args}
      {:ok, val} -> {:ok, [val]}
      {:error, _} -> {:error, "Invalid JSON: #{args_str}"}
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
