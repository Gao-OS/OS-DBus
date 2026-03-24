defmodule GaoBusTest.E2ETestService do
  @moduledoc """
  An Elixir D-Bus service for X→E test scenarios.

  Exports com.test.ElixirService on the test bus with:
  - Echo(s) → s
  - Add(i, i) → i
  - EmitSignal(s) — emits TestSignal with payload

  Manages its own connection and handles incoming method calls.
  """

  use GenServer

  alias ExDBus.{Connection, Message, Introspection}

  @bus_name "com.test.ElixirService"
  @object_path "/com/test/ElixirService"
  @interface "com.test.ElixirService"

  def bus_name, do: @bus_name
  def object_path, do: @object_path
  def interface, do: @interface

  def start(bus_address) do
    GenServer.start(__MODULE__, bus_address, name: __MODULE__)
  end

  def stop do
    if Process.whereis(__MODULE__) do
      GenServer.stop(__MODULE__, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  def get_connection do
    GenServer.call(__MODULE__, :get_connection)
  end

  @impl true
  def init(bus_address) do
    {:ok, conn} =
      Connection.start_link(
        address: bus_address,
        auth_mod: ExDBus.Auth.External,
        owner: self()
      )

    receive do
      {:ex_d_bus, {:connected, _guid}} -> :ok
    after
      10_000 -> {:stop, :connection_timeout}
    end

    # Hello
    hello =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _} = Connection.call(conn, hello, 5_000)

    # RequestName
    req =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        destination: "org.freedesktop.DBus",
        signature: "su",
        body: [@bus_name, 0]
      )

    {:ok, _} = Connection.call(conn, req, 5_000)

    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_call(:get_connection, _from, state) do
    {:reply, state.conn, state}
  end

  @impl true
  def handle_info({:ex_d_bus, {:message, msg}}, state) do
    case msg.type do
      :method_call -> handle_method_call(msg, state)
      _ -> {:noreply, state}
    end
  end

  def handle_info({:ex_d_bus, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  defp handle_method_call(msg, state) do
    reply =
      try do
        build_reply(msg, state)
      rescue
        e ->
          Message.error(
            "org.freedesktop.DBus.Error.InvalidArgs",
            msg.serial,
            destination: msg.sender,
            signature: "s",
            body: ["Error processing request: #{Exception.message(e)}"]
          )
      end

    Connection.cast(state.conn, reply)
    {:noreply, state}
  end

  defp build_reply(
         %{interface: "org.freedesktop.DBus.Introspectable", member: "Introspect"} = msg,
         _state
       ) do
    xml = build_introspection_xml()
    Message.method_return(msg.serial, destination: msg.sender, signature: "s", body: [xml])
  end

  defp build_reply(%{interface: "org.freedesktop.DBus.Properties"} = msg, _state) do
    Message.error(
      "org.freedesktop.DBus.Error.UnknownInterface",
      msg.serial,
      destination: msg.sender,
      signature: "s",
      body: ["Properties interface not implemented"]
    )
  end

  defp build_reply(%{interface: @interface, member: "Echo"} = msg, _state) do
    [input] = msg.body

    unless is_binary(input) do
      raise ArgumentError, "Echo expects a string, got: #{inspect(input)}"
    end

    Message.method_return(msg.serial, destination: msg.sender, signature: "s", body: [input])
  end

  defp build_reply(%{interface: @interface, member: "Add"} = msg, _state) do
    [a, b] = msg.body
    Message.method_return(msg.serial, destination: msg.sender, signature: "i", body: [a + b])
  end

  defp build_reply(%{interface: @interface, member: "EmitSignal"} = msg, state) do
    [payload] = msg.body

    signal =
      Message.signal(@object_path, @interface, "TestSignal",
        signature: "s",
        body: [payload]
      )

    Connection.send_signal(state.conn, signal)
    Message.method_return(msg.serial, destination: msg.sender)
  end

  defp build_reply(msg, _state) do
    Message.error(
      "org.freedesktop.DBus.Error.UnknownMethod",
      msg.serial,
      destination: msg.sender,
      signature: "s",
      body: ["No such method: #{msg.interface}.#{msg.member}"]
    )
  end

  defp build_introspection_xml do
    iface = %Introspection{
      name: @interface,
      methods: [
        %Introspection.Method{
          name: "Echo",
          args: [
            %Introspection.Arg{name: "input", type: "s", direction: :in},
            %Introspection.Arg{name: "output", type: "s", direction: :out}
          ]
        },
        %Introspection.Method{
          name: "Add",
          args: [
            %Introspection.Arg{name: "a", type: "i", direction: :in},
            %Introspection.Arg{name: "b", type: "i", direction: :in},
            %Introspection.Arg{name: "sum", type: "i", direction: :out}
          ]
        },
        %Introspection.Method{
          name: "EmitSignal",
          args: [
            %Introspection.Arg{name: "payload", type: "s", direction: :in}
          ]
        }
      ],
      signals: [
        %Introspection.Signal{
          name: "TestSignal",
          args: [
            %Introspection.Arg{name: "payload", type: "s"}
          ]
        }
      ],
      properties: []
    }

    Introspection.to_xml(@object_path, [
      iface,
      Introspection.introspectable_interface(),
      Introspection.peer_interface()
    ])
  end
end
