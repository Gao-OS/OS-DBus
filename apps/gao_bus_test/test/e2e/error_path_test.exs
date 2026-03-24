defmodule GaoBusTest.E2E.ErrorPathTest do
  @moduledoc """
  E2E scenarios 21-25: Error and failure paths.
  """
  use ExUnit.Case, async: false

  alias GaoBusTest.E2EHarness
  alias GaoBusTest.E2ETestService
  alias ExDBus.{Connection, Message, Proxy}

  @moduletag :e2e
  @moduletag group: :errors
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

  # --- Scenario 21: Elixir calls unavailable service ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#21 Elixir calls unavailable service — predictable error", %{state: state} do
    proxy =
      Proxy.new(
        state.elixir_conn,
        "com.test.NonExistentService",
        "/com/test/NonExistentService"
      )

    result =
      Proxy.call(proxy, "com.test.NonExistentService", "DoSomething", timeout: 3_000)

    assert {:error, _reason} = result
  end

  # --- Scenario 22: Elixir method call timeout ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#22 Elixir method call timeout via SlowEcho", %{state: state} do
    proxy =
      Proxy.new(
        state.elixir_conn,
        E2EHarness.fixture_bus_name(),
        E2EHarness.fixture_object_path()
      )

    # Request a 5s delay but set 2s timeout
    result =
      try do
        Proxy.call(proxy, E2EHarness.fixture_interface(), "SlowEcho",
          signature: "us",
          body: [5_000, "should_timeout"],
          timeout: 2_000
        )
      catch
        :exit, _ -> {:error, :timeout}
      end

    assert {:error, _reason} = result
  end

  # --- Scenario 23: Peer termination mid-session ---
  @tag gate: :release
  @tag direction: :elixir_to_external
  test "#23 Peer termination — Elixir handles disconnect without crash", %{state: state} do
    # Connect a second Elixir client that we'll disconnect
    {:ok, temp_conn} =
      Connection.start_link(
        address: state.bus_address,
        auth_mod: ExDBus.Auth.External,
        owner: self()
      )

    receive do
      {:ex_d_bus, {:connected, _}} -> :ok
    after
      5_000 -> raise "timeout"
    end

    hello =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _} = Connection.call(temp_conn, hello, 5_000)

    # Disconnect abruptly
    Connection.disconnect(temp_conn)
    Process.sleep(500)

    # Original connection should still work
    proxy =
      Proxy.new(
        state.elixir_conn,
        E2EHarness.fixture_bus_name(),
        E2EHarness.fixture_object_path()
      )

    {:ok, reply} =
      Proxy.call(proxy, "com.test.ExternalFixture", "Echo",
        signature: "s",
        body: ["after_peer_disconnect"]
      )

    assert reply.body == ["after_peer_disconnect"]
  end

  # --- Scenario 24: Bus daemon termination ---
  @tag gate: :release
  test "#24 Bus daemon termination — Elixir detects disconnect" do
    # Start a separate, dedicated bus for this test
    {:ok, local_state} = E2EHarness.start_bus()

    {:ok, conn} =
      Connection.start_link(
        address: local_state.bus_address,
        auth_mod: ExDBus.Auth.External,
        owner: self()
      )

    receive do
      {:ex_d_bus, {:connected, _}} -> :ok
    after
      5_000 -> raise "timeout"
    end

    hello =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _} = Connection.call(conn, hello, 5_000)

    # Kill the bus daemon
    if local_state.daemon_pid do
      System.cmd("kill", ["-TERM", "#{local_state.daemon_pid}"], stderr_to_stdout: true)
    end

    # Should receive disconnect notification or connection should error
    received_disconnect =
      receive do
        {:ex_d_bus, :disconnected} -> true
        {:ex_d_bus, {:disconnected}} -> true
        {:ex_d_bus, {:connection_error, _}} -> true
        {:DOWN, _, :process, ^conn, _} -> true
      after
        5_000 -> false
      end

    # Clean up connection (may already be dead after bus termination)
    try do
      Connection.disconnect(conn)
    catch
      _, _ -> :ok
    end

    # Clean up bus resources (daemon already killed, avoid double-kill)
    E2EHarness.cleanup(%{local_state | daemon_pid: nil, daemon_port: nil})

    assert received_disconnect, "Should detect bus daemon termination"
  end

  # --- Scenario 25: Invalid/malformed request ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#25 Invalid method call — error response, no crash", %{state: state} do
    # Call with wrong signature/args
    {_output, _code} =
      E2EHarness.busctl(state, [
        "call",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        E2ETestService.interface(),
        "Echo",
        "u",
        "12345"
      ])

    # The service should return an error or mismatch, not crash
    # Verify service is still alive
    {echo_output, echo_code} =
      E2EHarness.busctl(state, [
        "call",
        E2ETestService.bus_name(),
        E2ETestService.object_path(),
        E2ETestService.interface(),
        "Echo",
        "s",
        "still_alive"
      ])

    assert echo_code == 0, "Service crashed after malformed request: #{echo_output}"
    assert echo_output =~ "still_alive"
  end
end
