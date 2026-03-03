defmodule ExDBus.Object do
  @moduledoc """
  Behaviour for exporting Elixir modules as D-Bus objects.

  Implement this behaviour to define a D-Bus object that can handle
  method calls, expose properties, and emit signals.

  ## Usage

      defmodule MyService do
        @behaviour ExDBus.Object

        @impl true
        def interfaces do
          [
            %ExDBus.Introspection{
              name: "com.example.MyInterface",
              methods: [
                %ExDBus.Introspection.Method{
                  name: "DoStuff",
                  args: [
                    %ExDBus.Introspection.Arg{name: "input", type: "s", direction: :in},
                    %ExDBus.Introspection.Arg{name: "output", type: "s", direction: :out}
                  ]
                }
              ]
            }
          ]
        end

        @impl true
        def handle_method("com.example.MyInterface", "DoStuff", [input]) do
          {:ok, "s", [String.upcase(input)]}
        end
      end
  """

  alias ExDBus.{Introspection, Message}

  @doc """
  Return the list of interfaces this object exports.
  """
  @callback interfaces() :: [Introspection.t()]

  @doc """
  Handle a method call.

  Returns:
  - `{:ok, signature, body}` for success
  - `{:error, error_name, error_message}` for D-Bus errors
  """
  @callback handle_method(interface :: String.t(), method :: String.t(), args :: list()) ::
              {:ok, String.t() | nil, list()} | {:error, String.t(), String.t()}

  @doc """
  Get a property value. Return `{:ok, signature, value}` or `{:error, error_name, msg}`.
  """
  @callback get_property(interface :: String.t(), property :: String.t()) ::
              {:ok, String.t(), term()} | {:error, String.t(), String.t()}

  @doc """
  Set a property value. Return `:ok` or `{:error, error_name, msg}`.
  """
  @callback set_property(interface :: String.t(), property :: String.t(), value :: term()) ::
              :ok | {:error, String.t(), String.t()}

  @optional_callbacks [get_property: 2, set_property: 3]

  @doc """
  Dispatch a method_call message to an object module.

  Returns `{:ok, reply_message}` or `{:error, error_message}`.
  """
  @spec dispatch(Message.t(), module()) :: {:ok, Message.t()} | {:error, Message.t()}
  def dispatch(%Message{type: :method_call} = msg, object_mod) do
    cond do
      msg.interface == "org.freedesktop.DBus.Introspectable" and msg.member == "Introspect" ->
        handle_introspect(msg, object_mod)

      msg.interface == "org.freedesktop.DBus.Properties" ->
        handle_properties(msg, object_mod)

      msg.interface == "org.freedesktop.DBus.Peer" ->
        handle_peer(msg)

      true ->
        handle_object_method(msg, object_mod)
    end
  end

  defp handle_introspect(msg, object_mod) do
    interfaces =
      object_mod.interfaces() ++
        [
          Introspection.introspectable_interface(),
          Introspection.properties_interface(),
          Introspection.peer_interface()
        ]

    xml = Introspection.to_xml(msg.path || "/", interfaces)

    reply =
      Message.method_return(msg.serial,
        destination: msg.sender,
        signature: "s",
        body: [xml]
      )

    {:ok, reply}
  end

  defp handle_properties(msg, object_mod) do
    Code.ensure_loaded(object_mod)

    case msg.member do
      "Get" -> handle_property_get(msg, object_mod)
      "Set" -> handle_property_set(msg, object_mod)
      "GetAll" -> handle_property_get_all(msg)
      _ -> property_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method: #{msg.member}")
    end
  end

  defp handle_property_get(msg, object_mod) do
    [interface, property] = msg.body

    if function_exported?(object_mod, :get_property, 2) do
      case object_mod.get_property(interface, property) do
        {:ok, sig, value} ->
          {:ok,
           Message.method_return(msg.serial,
             destination: msg.sender,
             signature: "v",
             body: [{sig, value}]
           )}

        {:error, error_name, error_msg} ->
          property_error(msg, error_name, error_msg)
      end
    else
      property_error(msg, "org.freedesktop.DBus.Error.UnknownProperty", "Property not found: #{property}")
    end
  end

  defp handle_property_set(msg, object_mod) do
    [interface, property, {_sig, value}] = msg.body

    if function_exported?(object_mod, :set_property, 3) do
      case object_mod.set_property(interface, property, value) do
        :ok ->
          {:ok, Message.method_return(msg.serial, destination: msg.sender)}

        {:error, error_name, error_msg} ->
          property_error(msg, error_name, error_msg)
      end
    else
      property_error(msg, "org.freedesktop.DBus.Error.PropertyReadOnly", "Property not writable: #{property}")
    end
  end

  defp handle_property_get_all(msg) do
    [_interface] = msg.body

    {:ok,
     Message.method_return(msg.serial,
       destination: msg.sender,
       signature: "a{sv}",
       body: [[]]
     )}
  end

  defp property_error(msg, error_name, error_msg) do
    {:error,
     Message.error(error_name, msg.serial,
       destination: msg.sender,
       signature: "s",
       body: [error_msg]
     )}
  end

  defp handle_peer(msg) do
    case msg.member do
      "Ping" ->
        {:ok, Message.method_return(msg.serial, destination: msg.sender)}

      "GetMachineId" ->
        machine_id =
          case File.read("/etc/machine-id") do
            {:ok, id} -> String.trim(id)
            _ -> "00000000000000000000000000000000"
          end

        {:ok,
         Message.method_return(msg.serial,
           destination: msg.sender,
           signature: "s",
           body: [machine_id]
         )}

      _ ->
        {:error,
         Message.error("org.freedesktop.DBus.Error.UnknownMethod", msg.serial,
           destination: msg.sender,
           signature: "s",
           body: ["Unknown method: #{msg.member}"]
         )}
    end
  end

  defp handle_object_method(msg, object_mod) do
    case object_mod.handle_method(msg.interface, msg.member, msg.body || []) do
      {:ok, signature, body} ->
        reply =
          Message.method_return(msg.serial,
            destination: msg.sender,
            signature: signature,
            body: body
          )

        {:ok, reply}

      {:error, error_name, error_msg} ->
        {:error,
         Message.error(error_name, msg.serial,
           destination: msg.sender,
           signature: "s",
           body: [error_msg]
         )}
    end
  end
end
