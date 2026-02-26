defmodule GaoConfig.DBusInterfaceTest do
  use ExUnit.Case

  alias ExDBus.Message
  alias GaoConfig.DBusInterface

  setup do
    GaoConfig.ConfigStore.clear()
    :ok
  end

  describe "Get" do
    test "returns value for existing key" do
      GaoConfig.ConfigStore.set("test", "key1", "value1")

      msg = Message.method_call("/org/gaoos/Config1", "org.gaoos.Config1", "Get",
        serial: 1, sender: ":1.1", signature: "ss", body: ["test", "key1"])

      assert {:ok, reply} = DBusInterface.handle_method(msg)
      assert reply.type == :method_return
      assert reply.body == ["value1"]
    end

    test "returns error for missing key" do
      msg = Message.method_call("/org/gaoos/Config1", "org.gaoos.Config1", "Get",
        serial: 1, sender: ":1.1", signature: "ss", body: ["test", "missing"])

      assert {:error, error} = DBusInterface.handle_method(msg)
      assert error.type == :error
      assert error.error_name == "org.gaoos.Config1.Error.NotFound"
    end
  end

  describe "Set" do
    test "sets a value" do
      msg = Message.method_call("/org/gaoos/Config1", "org.gaoos.Config1", "Set",
        serial: 1, sender: ":1.1", signature: "sss", body: ["net", "host", "gaoos"])

      assert {:ok, reply} = DBusInterface.handle_method(msg)
      assert reply.type == :method_return

      assert {:ok, "gaoos"} = GaoConfig.ConfigStore.get("net", "host")
    end
  end

  describe "Delete" do
    test "deletes a key" do
      GaoConfig.ConfigStore.set("test", "delme", "value")

      msg = Message.method_call("/org/gaoos/Config1", "org.gaoos.Config1", "Delete",
        serial: 1, sender: ":1.1", signature: "ss", body: ["test", "delme"])

      assert {:ok, _reply} = DBusInterface.handle_method(msg)
      assert {:error, :not_found} = GaoConfig.ConfigStore.get("test", "delme")
    end
  end

  describe "List" do
    test "lists keys in section" do
      GaoConfig.ConfigStore.set("sec", "a", "1")
      GaoConfig.ConfigStore.set("sec", "b", "2")

      msg = Message.method_call("/org/gaoos/Config1", "org.gaoos.Config1", "List",
        serial: 1, sender: ":1.1", signature: "s", body: ["sec"])

      assert {:ok, reply} = DBusInterface.handle_method(msg)
      assert reply.signature == "a{ss}"
      [pairs] = reply.body
      assert {"a", "1"} in pairs
      assert {"b", "2"} in pairs
    end
  end

  describe "ListSections" do
    test "lists all sections" do
      GaoConfig.ConfigStore.set("net", "x", "1")
      GaoConfig.ConfigStore.set("audio", "y", "2")

      msg = Message.method_call("/org/gaoos/Config1", "org.gaoos.Config1", "ListSections",
        serial: 1, sender: ":1.1")

      assert {:ok, reply} = DBusInterface.handle_method(msg)
      [sections] = reply.body
      assert "net" in sections
      assert "audio" in sections
    end
  end

  describe "GetVersion" do
    test "returns version" do
      msg = Message.method_call("/org/gaoos/Config1", "org.gaoos.Config1", "GetVersion",
        serial: 1, sender: ":1.1")

      assert {:ok, reply} = DBusInterface.handle_method(msg)
      assert reply.body == ["0.1.0"]
    end
  end

  describe "unknown method" do
    test "returns error for unknown method" do
      msg = Message.method_call("/org/gaoos/Config1", "org.gaoos.Config1", "Bogus",
        serial: 1, sender: ":1.1")

      assert {:error, error} = DBusInterface.handle_method(msg)
      assert error.error_name == "org.freedesktop.DBus.Error.UnknownMethod"
    end
  end
end
