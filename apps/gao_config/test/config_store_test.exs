defmodule GaoConfig.ConfigStoreTest do
  use ExUnit.Case

  setup do
    # Clear all entries before each test (uses the app-started store)
    GaoConfig.ConfigStore.clear()
    :ok
  end

  describe "get/set" do
    test "set and get a value" do
      :ok = GaoConfig.ConfigStore.set("network", "hostname", "gaoos-device")
      assert {:ok, "gaoos-device"} = GaoConfig.ConfigStore.get("network", "hostname")
    end

    test "get returns not_found for missing key" do
      assert {:error, :not_found} = GaoConfig.ConfigStore.get("network", "nonexistent")
    end

    test "set overwrites existing value" do
      :ok = GaoConfig.ConfigStore.set("display", "brightness", "50")
      :ok = GaoConfig.ConfigStore.set("display", "brightness", "80")
      assert {:ok, "80"} = GaoConfig.ConfigStore.get("display", "brightness")
    end
  end

  describe "delete" do
    test "delete removes a key" do
      :ok = GaoConfig.ConfigStore.set("audio", "volume", "75")
      assert {:ok, "75"} = GaoConfig.ConfigStore.get("audio", "volume")

      :ok = GaoConfig.ConfigStore.delete("audio", "volume")
      assert {:error, :not_found} = GaoConfig.ConfigStore.get("audio", "volume")
    end

    test "delete nonexistent key is ok" do
      :ok = GaoConfig.ConfigStore.delete("ghost", "key")
    end
  end

  describe "list" do
    test "list keys in a section" do
      :ok = GaoConfig.ConfigStore.set("network", "hostname", "gaoos")
      :ok = GaoConfig.ConfigStore.set("network", "dns", "8.8.8.8")
      :ok = GaoConfig.ConfigStore.set("display", "brightness", "50")

      entries = GaoConfig.ConfigStore.list("network")
      assert length(entries) == 2
      assert {"hostname", "gaoos"} in entries
      assert {"dns", "8.8.8.8"} in entries
    end

    test "list empty section returns empty" do
      assert GaoConfig.ConfigStore.list("empty") == []
    end
  end

  describe "list_sections" do
    test "lists all sections" do
      :ok = GaoConfig.ConfigStore.set("network", "hostname", "gaoos")
      :ok = GaoConfig.ConfigStore.set("display", "brightness", "50")
      :ok = GaoConfig.ConfigStore.set("audio", "volume", "75")

      sections = GaoConfig.ConfigStore.list_sections()
      assert "network" in sections
      assert "display" in sections
      assert "audio" in sections
    end
  end

  describe "persistence" do
    test "data survives restart" do
      :ok = GaoConfig.ConfigStore.set("test", "persist_key", "persist_value")

      # Stop the application's config store
      Application.stop(:gao_config)
      Process.sleep(50)

      # Restart the application
      Application.ensure_all_started(:gao_config)
      Process.sleep(50)

      assert {:ok, "persist_value"} = GaoConfig.ConfigStore.get("test", "persist_key")
    end
  end
end
