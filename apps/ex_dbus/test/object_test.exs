defmodule ExDBus.ObjectTest do
  use ExUnit.Case

  alias ExDBus.{Object, Message, Introspection}
  alias ExDBus.Introspection.{Method, Arg}

  # Test object implementation
  defmodule TestObject do
    @behaviour ExDBus.Object

    @impl true
    def interfaces do
      [
        %Introspection{
          name: "com.example.Test",
          methods: [
            %Method{
              name: "Echo",
              args: [
                %Arg{name: "input", type: "s", direction: :in},
                %Arg{name: "output", type: "s", direction: :out}
              ]
            },
            %Method{
              name: "Add",
              args: [
                %Arg{name: "a", type: "i", direction: :in},
                %Arg{name: "b", type: "i", direction: :in},
                %Arg{name: "sum", type: "i", direction: :out}
              ]
            }
          ]
        }
      ]
    end

    @impl true
    def handle_method("com.example.Test", "Echo", [input]) do
      {:ok, "s", [input]}
    end

    def handle_method("com.example.Test", "Add", [a, b]) do
      {:ok, "i", [a + b]}
    end

    def handle_method(_interface, method, _args) do
      {:error, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method: #{method}"}
    end

    @impl true
    def get_property("com.example.Test", "Version") do
      {:ok, "s", "1.0"}
    end

    def get_property(_interface, property) do
      {:error, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown: #{property}"}
    end
  end

  # Helper to build a message with sender set (sender isn't in the constructor opts)
  defp msg(path, interface, member, opts) do
    sender = Keyword.get(opts, :sender)
    base_opts = Keyword.delete(opts, :sender)
    msg = Message.method_call(path, interface, member, base_opts)
    %{msg | sender: sender}
  end

  describe "dispatch/2 — method calls" do
    test "dispatches to handle_method" do
      m = msg("/test", "com.example.Test", "Echo",
        serial: 1, sender: ":1.1", signature: "s", body: ["hello"])

      assert {:ok, reply} = Object.dispatch(m, TestObject)
      assert reply.type == :method_return
      assert reply.body == ["hello"]
      assert reply.destination == ":1.1"
    end

    test "dispatches with multiple args" do
      m = msg("/test", "com.example.Test", "Add",
        serial: 2, sender: ":1.1", signature: "ii", body: [3, 4])

      assert {:ok, reply} = Object.dispatch(m, TestObject)
      assert reply.body == [7]
    end

    test "returns error for unknown method" do
      m = msg("/test", "com.example.Test", "Nonexistent",
        serial: 3, sender: ":1.1")

      assert {:error, error} = Object.dispatch(m, TestObject)
      assert error.type == :error
      assert error.error_name == "org.freedesktop.DBus.Error.UnknownMethod"
    end
  end

  describe "dispatch/2 — introspection" do
    test "handles Introspect" do
      m = msg("/test", "org.freedesktop.DBus.Introspectable", "Introspect",
        serial: 1, sender: ":1.1")

      assert {:ok, reply} = Object.dispatch(m, TestObject)
      assert reply.type == :method_return
      [xml] = reply.body
      assert String.contains?(xml, "com.example.Test")
      assert String.contains?(xml, "Echo")
      assert String.contains?(xml, "org.freedesktop.DBus.Introspectable")
    end
  end

  describe "dispatch/2 — properties" do
    test "handles Properties.Get" do
      m = msg("/test", "org.freedesktop.DBus.Properties", "Get",
        serial: 1, sender: ":1.1", signature: "ss",
        body: ["com.example.Test", "Version"])

      assert {:ok, reply} = Object.dispatch(m, TestObject)
      assert reply.type == :method_return
      assert reply.body == [{"s", "1.0"}]
    end

    test "handles Properties.Get for unknown property" do
      m = msg("/test", "org.freedesktop.DBus.Properties", "Get",
        serial: 1, sender: ":1.1", signature: "ss",
        body: ["com.example.Test", "Bogus"])

      assert {:error, error} = Object.dispatch(m, TestObject)
      assert error.error_name == "org.freedesktop.DBus.Error.UnknownProperty"
    end
  end

  describe "dispatch/2 — peer interface" do
    test "handles Ping" do
      m = msg("/test", "org.freedesktop.DBus.Peer", "Ping",
        serial: 1, sender: ":1.1")

      assert {:ok, reply} = Object.dispatch(m, TestObject)
      assert reply.type == :method_return
    end

    test "handles GetMachineId" do
      m = msg("/test", "org.freedesktop.DBus.Peer", "GetMachineId",
        serial: 1, sender: ":1.1")

      assert {:ok, reply} = Object.dispatch(m, TestObject)
      assert reply.type == :method_return
      [id] = reply.body
      assert is_binary(id)
    end
  end
end
