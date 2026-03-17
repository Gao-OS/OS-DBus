defmodule GaoBusTest.E2E.SignalTest do
  @moduledoc """
  E2E scenarios 7-10: Signal emission and reception.
  """
  use ExUnit.Case, async: false

  alias GaoBusTest.E2EHarness
  alias GaoBusTest.E2ETestService
  alias ExDBus.{Connection, Message, Proxy}

  @moduletag :e2e
  @moduletag group: :signals
  @moduletag timeout: 120_000

  setup_all do
    unless E2EHarness.tools_available?() do
      raise "Required tools (dbus-daemon, busctl, gdbus) not found"
    end

    {:ok, state} = E2EHarness.start_bus()
    {:ok, state} = E2EHarness.start_fixture(state)
    {:ok, state} = E2EHarness.connect_elixir(state)

    {:ok, _} = E2ETestService.start(state.bus_address)

    on_exit(fn ->
      E2ETestService.stop()
      E2EHarness.cleanup(state)
    end)

    {:ok, state: state}
  end

  # --- Scenario 7: Elixir emits signal, busctl observes ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#7 Elixir emits signal, busctl monitor observes it", %{state: state} do
    payload = "signal_for_busctl_#{System.unique_integer([:positive])}"

    # Start busctl monitor in background
    monitor_port = E2EHarness.busctl_monitor(state, [E2ETestService.bus_name()])
    Process.sleep(500)

    # Trigger signal emission via method call
    {_output, 0} =
      E2EHarness.busctl(state, [
        "call",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        E2ETestService.interface(),
        "EmitSignal",
        "s",
        payload
      ])

    # Collect monitor output
    Process.sleep(1_000)
    output = collect_port_output(monitor_port)
    safe_close_port(monitor_port)

    assert output =~ payload or output =~ "TestSignal",
           "Expected signal in busctl monitor output, got: #{output}"
  end

  # --- Scenario 8: Elixir emits signal, gdbus observes ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#8 Elixir emits signal, gdbus monitor observes it", %{state: state} do
    payload = "signal_for_gdbus_#{System.unique_integer([:positive])}"

    # Start gdbus monitor
    monitor_port =
      E2EHarness.gdbus_monitor(state, [
        "--dest=#{E2ETestService.bus_name()}"
      ])

    Process.sleep(500)

    # Trigger signal
    {_output, 0} =
      E2EHarness.gdbus(state, [
        "call",
        "--dest=#{E2ETestService.bus_name()}",
        "--object-path=#{E2ETestService.object_path()}",
        "--method=#{E2ETestService.interface()}.EmitSignal",
        payload
      ])

    Process.sleep(1_000)
    output = collect_port_output(monitor_port)
    safe_close_port(monitor_port)

    assert output =~ payload or output =~ "TestSignal",
           "Expected signal in gdbus monitor output, got: #{output}"
  end

  # --- Scenario 9: Fixture emits signal, Elixir receives ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#9 Fixture emits signal, Elixir receives it", %{state: state} do
    payload = "signal_from_fixture_#{System.unique_integer([:positive])}"

    # Create a dedicated connection owned by this test process
    {:ok, sig_conn} = connect_for_signals(state.bus_address)

    # Subscribe to signals via AddMatch
    add_match =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: [
          "type='signal',interface='#{E2EHarness.fixture_interface()}',member='TestSignal'"
        ]
      )

    {:ok, _} = Connection.call(sig_conn, add_match, 5_000)

    # Tell fixture to emit signal (use the shared conn for the call)
    proxy =
      Proxy.new(
        sig_conn,
        E2EHarness.fixture_bus_name(),
        E2EHarness.fixture_object_path()
      )

    {:ok, _} =
      Proxy.call(proxy, E2EHarness.fixture_interface(), "EmitTestSignal",
        signature: "s",
        body: [payload]
      )

    # Wait for signal message (sent to this process as owner)
    received =
      receive do
        {:ex_dbus, {:message, %{type: :signal, member: "TestSignal"} = msg}} ->
          msg
      after
        5_000 -> nil
      end

    Connection.disconnect(sig_conn)

    assert received != nil, "Did not receive TestSignal within timeout"
    assert received.body == [payload]
  end

  # --- Scenario 10: Signal with match rule filtering ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#10 Signal match rule filtering — only matched signals delivered", %{state: state} do
    # Create a dedicated connection owned by this test process
    {:ok, sig_conn} = connect_for_signals(state.bus_address)

    # Subscribe ONLY to TestSignal from the fixture interface
    add_match =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: [
          "type='signal',interface='#{E2EHarness.fixture_interface()}',member='TestSignal'"
        ]
      )

    {:ok, _} = Connection.call(sig_conn, add_match, 5_000)

    proxy =
      Proxy.new(
        sig_conn,
        E2EHarness.fixture_bus_name(),
        E2EHarness.fixture_object_path()
      )

    # First: emit an unrelated signal from the Elixir test service (different interface)
    # This should NOT be delivered because our match rule filters on com.test.ExternalFixture
    service_conn = E2ETestService.get_connection()

    unmatched_signal =
      Message.signal(
        "/com/test/ElixirService",
        "com.test.ElixirService",
        "UnrelatedSignal",
        signature: "s",
        body: ["should_not_arrive"]
      )

    Connection.send_signal(service_conn, unmatched_signal)

    # Brief pause to let the unmatched signal propagate (or not)
    Process.sleep(200)

    # Now emit the matched signal
    {:ok, _} =
      Proxy.call(proxy, E2EHarness.fixture_interface(), "EmitTestSignal",
        signature: "s",
        body: ["matched_payload"]
      )

    # We should receive the matched signal
    received =
      receive do
        {:ex_dbus, {:message, %{type: :signal, member: "TestSignal"} = msg}} ->
          msg
      after
        5_000 -> nil
      end

    # Drain mailbox — verify no unmatched signals arrived
    unmatched =
      receive do
        {:ex_dbus, {:message, %{type: :signal, member: "UnrelatedSignal"}}} -> true
      after
        200 -> false
      end

    Connection.disconnect(sig_conn)

    assert received != nil, "Should receive matched signal"
    assert received.body == ["matched_payload"]
    refute unmatched, "Should NOT receive signals that don't match the rule"
  end

  defp connect_for_signals(bus_address) do
    {:ok, conn} =
      Connection.start_link(
        address: bus_address,
        auth_mod: ExDBus.Auth.External,
        owner: self()
      )

    receive do
      {:ex_dbus, {:connected, _}} -> :ok
    after
      5_000 -> raise "signal connection timeout"
    end

    hello =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _} = Connection.call(conn, hello, 5_000)
    {:ok, conn}
  end

  defp collect_port_output(port) do
    receive do
      {^port, {:data, data}} ->
        data <> collect_port_output(port)
    after
      100 -> ""
    end
  end

  defp safe_close_port(port) do
    try do
      {:os_pid, pid} = Port.info(port, :os_pid)
      System.cmd("kill", ["-TERM", "#{pid}"], stderr_to_stdout: true)
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
end
