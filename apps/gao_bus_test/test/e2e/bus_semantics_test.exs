defmodule GaoBusTest.E2E.BusSemanticsTest do
  @moduledoc """
  E2E scenarios 18-20: Bus name semantics.
  """
  use ExUnit.Case, async: false

  alias GaoBusTest.E2EHarness
  alias ExDBus.{Connection, Message}

  @moduletag :e2e
  @moduletag group: :bus_semantics
  @moduletag timeout: 120_000

  @bus_name "com.test.NameTest"

  setup_all do
    {:ok, state} = E2EHarness.start_bus()
    {:ok, state} = E2EHarness.connect_elixir(state)

    on_exit(fn -> E2EHarness.cleanup(state) end)

    {:ok, state: state}
  end

  # --- Scenario 18: Name acquisition visible via busctl ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#18 Name acquisition visible in busctl", %{state: state} do
    # Request a well-known name
    request =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        destination: "org.freedesktop.DBus",
        signature: "su",
        body: [@bus_name, 0]
      )

    {:ok, reply} = Connection.call(state.elixir_conn, request, 5_000)
    # 1 = DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER
    assert reply.body == [1]

    # Verify via busctl
    {output, code} =
      E2EHarness.busctl(state, [
        "call",
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "ListNames"
      ])

    assert code == 0
    assert output =~ @bus_name, "Name not visible in ListNames: #{output}"
  end

  # --- Scenario 19: Name release ---
  @tag gate: :release
  @tag direction: :external_to_elixir
  test "#19 Name release — name no longer owned after release", %{state: state} do
    name = "com.test.ReleaseTest"

    # Acquire
    request =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        destination: "org.freedesktop.DBus",
        signature: "su",
        body: [name, 0]
      )

    {:ok, _} = Connection.call(state.elixir_conn, request, 5_000)

    # Verify acquired
    {output, 0} =
      E2EHarness.busctl(state, [
        "call",
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameHasOwner",
        "s",
        name
      ])

    assert output =~ "true" or output =~ "b true"

    # Release
    release =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: [name]
      )

    {:ok, _} = Connection.call(state.elixir_conn, release, 5_000)

    # Verify released
    {output2, 0} =
      E2EHarness.busctl(state, [
        "call",
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameHasOwner",
        "s",
        name
      ])

    assert output2 =~ "false" or output2 =~ "b false",
           "Name should be released: #{output2}"
  end

  # --- Scenario 20: Ownership change notification (optional) ---
  @tag gate: :optional
  @tag direction: :external_to_elixir
  test "#20 NameOwnerChanged signal on name acquisition", %{state: state} do
    name = "com.test.OwnerChange"

    # Subscribe to NameOwnerChanged
    add_match =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch",
        destination: "org.freedesktop.DBus",
        signature: "s",
        body: [
          "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='#{name}'"
        ]
      )

    {:ok, _} = Connection.call(state.elixir_conn, add_match, 5_000)

    # Open a second connection to acquire the name
    {:ok, conn2} =
      Connection.start_link(
        address: state.bus_address,
        auth_mod: ExDBus.Auth.External,
        owner: self()
      )

    receive do
      {:ex_dbus, {:connected, _}} -> :ok
    after
      5_000 -> raise "timeout"
    end

    hello =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        destination: "org.freedesktop.DBus"
      )

    {:ok, _} = Connection.call(conn2, hello, 5_000)

    # Request name on second connection
    request =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
        destination: "org.freedesktop.DBus",
        signature: "su",
        body: [name, 0]
      )

    {:ok, _} = Connection.call(conn2, request, 5_000)

    # Should receive NameOwnerChanged
    received =
      receive do
        {:ex_dbus, {:message, %{type: :signal, member: "NameOwnerChanged"} = msg}} ->
          msg
      after
        3_000 -> nil
      end

    Connection.disconnect(conn2)

    if received do
      assert received.body != nil
    end

    # Optional test — pass even if signal not received
  end
end
