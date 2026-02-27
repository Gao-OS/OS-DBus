defmodule GaoConfig.DBusInterfaceTest do
  use ExUnit.Case

  alias ExDBus.{Message, Object}
  alias GaoConfig.DBusInterface

  setup do
    GaoConfig.ConfigStore.clear()
    :ok
  end

  # Helper to build a message with sender set
  defp msg(path, interface, member, opts) do
    sender = Keyword.get(opts, :sender)
    base_opts = Keyword.delete(opts, :sender)
    m = Message.method_call(path, interface, member, base_opts)
    %{m | sender: sender}
  end

  describe "Object.dispatch — Get" do
    test "returns value for existing key" do
      GaoConfig.ConfigStore.set("test", "key1", "value1")

      m = msg("/org/gaoos/Config1", "org.gaoos.Config1", "Get",
        serial: 1, sender: ":1.1", signature: "ss", body: ["test", "key1"])

      assert {:ok, reply} = Object.dispatch(m, DBusInterface)
      assert reply.type == :method_return
      assert reply.body == ["value1"]
    end

    test "returns error for missing key" do
      m = msg("/org/gaoos/Config1", "org.gaoos.Config1", "Get",
        serial: 1, sender: ":1.1", signature: "ss", body: ["test", "missing"])

      assert {:error, error} = Object.dispatch(m, DBusInterface)
      assert error.type == :error
      assert error.error_name == "org.gaoos.Config1.Error.NotFound"
    end
  end

  describe "Object.dispatch — Set" do
    test "sets a value" do
      m = msg("/org/gaoos/Config1", "org.gaoos.Config1", "Set",
        serial: 1, sender: ":1.1", signature: "sss", body: ["net", "host", "gaoos"])

      assert {:ok, reply} = Object.dispatch(m, DBusInterface)
      assert reply.type == :method_return

      assert {:ok, "gaoos"} = GaoConfig.ConfigStore.get("net", "host")
    end
  end

  describe "Object.dispatch — Delete" do
    test "deletes a key" do
      GaoConfig.ConfigStore.set("test", "delme", "value")

      m = msg("/org/gaoos/Config1", "org.gaoos.Config1", "Delete",
        serial: 1, sender: ":1.1", signature: "ss", body: ["test", "delme"])

      assert {:ok, _reply} = Object.dispatch(m, DBusInterface)
      assert {:error, :not_found} = GaoConfig.ConfigStore.get("test", "delme")
    end
  end

  describe "Object.dispatch — List" do
    test "lists keys in section" do
      GaoConfig.ConfigStore.set("sec", "a", "1")
      GaoConfig.ConfigStore.set("sec", "b", "2")

      m = msg("/org/gaoos/Config1", "org.gaoos.Config1", "List",
        serial: 1, sender: ":1.1", signature: "s", body: ["sec"])

      assert {:ok, reply} = Object.dispatch(m, DBusInterface)
      assert reply.signature == "a{ss}"
      [pairs] = reply.body
      assert {"a", "1"} in pairs
      assert {"b", "2"} in pairs
    end
  end

  describe "Object.dispatch — ListSections" do
    test "lists all sections" do
      GaoConfig.ConfigStore.set("net", "x", "1")
      GaoConfig.ConfigStore.set("audio", "y", "2")

      m = msg("/org/gaoos/Config1", "org.gaoos.Config1", "ListSections",
        serial: 1, sender: ":1.1")

      assert {:ok, reply} = Object.dispatch(m, DBusInterface)
      [sections] = reply.body
      assert "net" in sections
      assert "audio" in sections
    end
  end

  describe "Object.dispatch — GetVersion" do
    test "returns version" do
      m = msg("/org/gaoos/Config1", "org.gaoos.Config1", "GetVersion",
        serial: 1, sender: ":1.1")

      assert {:ok, reply} = Object.dispatch(m, DBusInterface)
      assert reply.body == ["0.1.0"]
    end
  end

  describe "Object.dispatch — unknown method" do
    test "returns error for unknown method" do
      m = msg("/org/gaoos/Config1", "org.gaoos.Config1", "Bogus",
        serial: 1, sender: ":1.1")

      assert {:error, error} = Object.dispatch(m, DBusInterface)
      assert error.error_name == "org.freedesktop.DBus.Error.UnknownMethod"
    end
  end

  describe "Object.dispatch — Introspect" do
    test "returns introspection XML with Config1 interface" do
      m = msg("/org/gaoos/Config1", "org.freedesktop.DBus.Introspectable", "Introspect",
        serial: 1, sender: ":1.1")

      assert {:ok, reply} = Object.dispatch(m, DBusInterface)
      [xml] = reply.body
      assert String.contains?(xml, "org.gaoos.Config1")
      assert String.contains?(xml, "Get")
      assert String.contains?(xml, "Set")
      assert String.contains?(xml, "ConfigChanged")
    end
  end

  describe "Object.dispatch — Properties" do
    test "Get returns Version property" do
      m = msg("/org/gaoos/Config1", "org.freedesktop.DBus.Properties", "Get",
        serial: 1, sender: ":1.1", signature: "ss",
        body: ["org.gaoos.Config1", "Version"])

      assert {:ok, reply} = Object.dispatch(m, DBusInterface)
      assert reply.body == [{"s", "0.1.0"}]
    end

    test "Get returns error for unknown property" do
      m = msg("/org/gaoos/Config1", "org.freedesktop.DBus.Properties", "Get",
        serial: 1, sender: ":1.1", signature: "ss",
        body: ["org.gaoos.Config1", "Bogus"])

      assert {:error, error} = Object.dispatch(m, DBusInterface)
      assert error.error_name == "org.freedesktop.DBus.Error.UnknownProperty"
    end
  end
end
