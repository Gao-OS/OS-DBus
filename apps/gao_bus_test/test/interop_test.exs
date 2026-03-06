defmodule GaoBusTest.InteropTest do
  @moduledoc """
  Interop compliance tests using real D-Bus tools (dbus-send, busctl)
  against gao_bus.

  These tests verify that gao_bus is compatible with standard D-Bus clients.
  They require the AUTH handshake to fully match the reference dbus-daemon
  implementation (SASL EXTERNAL with SO_PEERCRED).

  These tests are tagged `:interop` and excluded by default.
  Run with: mix test --include interop
  """
  use ExUnit.Case

  @moduletag :interop

  @socket_path "/tmp/gao_bus_interop_#{System.unique_integer([:positive])}"

  @dbus_send System.find_executable("dbus-send")
  @busctl System.find_executable("busctl")

  setup_all do
    Application.stop(:gao_bus)
    Process.sleep(100)

    Application.put_env(:gao_bus, :socket_path, @socket_path)
    {:ok, _} = Application.ensure_all_started(:gao_bus)
    Process.sleep(200)

    on_exit(fn ->
      Application.stop(:gao_bus)
      File.rm(@socket_path)
    end)

    :ok
  end

  describe "dbus-send" do
    @describetag skip: if(is_nil(@dbus_send), do: "dbus-send not installed")

    test "Hello via dbus-send" do
      {output, code} =
        run_dbus_send([
          "--print-reply",
          "--dest=org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus.Hello"
        ])

      assert code == 0, "dbus-send Hello failed (exit #{code}): #{output}"
      assert output =~ "string"
      assert output =~ ":1."
    end

    test "ListNames via dbus-send" do
      {output, code} =
        run_dbus_send([
          "--print-reply",
          "--dest=org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus.ListNames"
        ])

      assert code == 0, "dbus-send ListNames failed (exit #{code}): #{output}"
      assert output =~ "array"
      assert output =~ "org.freedesktop.DBus"
    end

    test "GetId via dbus-send" do
      {output, code} =
        run_dbus_send([
          "--print-reply",
          "--dest=org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus.GetId"
        ])

      assert code == 0, "dbus-send GetId failed (exit #{code}): #{output}"
      assert output =~ "string"
    end

    test "Introspect via dbus-send" do
      {output, code} =
        run_dbus_send([
          "--print-reply",
          "--dest=org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus.Introspectable.Introspect"
        ])

      assert code == 0, "dbus-send Introspect failed (exit #{code}): #{output}"
      assert output =~ "<interface"
      assert output =~ "org.freedesktop.DBus"
    end

    test "NameHasOwner via dbus-send" do
      {output, code} =
        run_dbus_send([
          "--print-reply",
          "--dest=org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus.NameHasOwner",
          "string:org.freedesktop.DBus"
        ])

      assert code == 0, "dbus-send NameHasOwner failed (exit #{code}): #{output}"
      assert output =~ "boolean true"
    end
  end

  describe "busctl" do
    @describetag skip: if(is_nil(@busctl), do: "busctl not installed")

    test "busctl list shows bus name" do
      {output, code} = run_busctl(["list", "--no-pager"])

      assert code == 0, "busctl list failed (exit #{code}): #{output}"
      assert output =~ "org.freedesktop.DBus"
    end

    test "busctl call Hello" do
      {output, code} =
        run_busctl([
          "call",
          "org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus",
          "Hello"
        ])

      assert code == 0, "busctl call Hello failed (exit #{code}): #{output}"
      assert output =~ ":1."
    end

    test "busctl call ListNames" do
      {output, code} =
        run_busctl([
          "call",
          "org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "org.freedesktop.DBus",
          "ListNames"
        ])

      assert code == 0, "busctl call ListNames failed (exit #{code}): #{output}"
      assert output =~ "org.freedesktop.DBus"
    end

    test "busctl introspect" do
      {output, code} =
        run_busctl([
          "introspect",
          "org.freedesktop.DBus",
          "/org/freedesktop/DBus",
          "--no-pager"
        ])

      assert code == 0, "busctl introspect failed (exit #{code}): #{output}"
      assert output =~ "Hello"
      assert output =~ "ListNames"
    end
  end

  # --- Helpers ---

  defp run_dbus_send(args) do
    System.cmd(@dbus_send, ["--bus=unix:path=#{@socket_path}" | args],
      stderr_to_stdout: true,
      env: [{"DBUS_SESSION_BUS_ADDRESS", "unix:path=#{@socket_path}"}]
    )
  rescue
    e -> {"helper error: #{Exception.message(e)}", 1}
  end

  defp run_busctl(args) do
    System.cmd(@busctl, ["--bus-path=#{@socket_path}" | args],
      stderr_to_stdout: true,
      env: [
        {"DBUS_SESSION_BUS_ADDRESS", "unix:path=#{@socket_path}"},
        {"DBUS_SYSTEM_BUS_ADDRESS", "unix:path=#{@socket_path}"}
      ]
    )
  rescue
    e -> {"helper error: #{Exception.message(e)}", 1}
  end
end
