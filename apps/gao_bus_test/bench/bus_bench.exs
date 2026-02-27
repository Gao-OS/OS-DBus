# Bus routing throughput benchmark
#
# Starts gao_bus, connects N client peers, and measures message routing throughput.
# Run with: mix run apps/gao_bus_test/bench/bus_bench.exs

alias ExDBus.{Connection, Message}

defmodule BusBench.Helpers do
  @doc "Connect a client peer and call Hello to get a unique name."
  def connect_peer(socket_path) do
    address = "unix:path=#{socket_path}"

    {:ok, conn} =
      Connection.start_link(
        address: address,
        auth_mod: ExDBus.Auth.Anonymous,
        owner: self()
      )

    receive do
      {:ex_dbus, {:connected, _guid}} -> :ok
    after
      2_000 -> raise "connection timeout"
    end

    # Call Hello
    hello =
      Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        serial: 1,
        destination: "org.freedesktop.DBus"
      )

    Connection.call(conn, hello, 2_000)
    conn
  end

  @doc "Send a method_call through the bus and wait for reply."
  def roundtrip_call(conn, dest, serial) do
    msg =
      Message.method_call("/", "org.freedesktop.DBus", "GetId",
        serial: serial,
        destination: dest
      )

    Connection.call(conn, msg, 5_000)
  end
end

IO.puts("Starting bus benchmark...")
IO.puts("=" |> String.duplicate(60))

# Ensure gao_bus is running
socket_path = "/tmp/gao_bus_bench_#{System.unique_integer([:positive])}"
Application.put_env(:gao_bus, :socket_path, socket_path)

Application.stop(:gao_bus)
Process.sleep(100)
{:ok, _} = Application.ensure_all_started(:gao_bus)
Process.sleep(200)

IO.puts("\n1. Single-peer method_call throughput")
IO.puts("-" |> String.duplicate(40))

conn = BusBench.Helpers.connect_peer(socket_path)
Process.sleep(100)

# Warm up
for i <- 1..10 do
  BusBench.Helpers.roundtrip_call(conn, "org.freedesktop.DBus", 100 + i)
end

# Measure
iterations = 1_000

{elapsed_us, _} =
  :timer.tc(fn ->
    for i <- 1..iterations do
      BusBench.Helpers.roundtrip_call(conn, "org.freedesktop.DBus", 1000 + i)
    end
  end)

elapsed_ms = elapsed_us / 1_000
per_call_us = elapsed_us / iterations
calls_per_sec = iterations / (elapsed_us / 1_000_000)

IO.puts("  #{iterations} method_calls in #{Float.round(elapsed_ms, 1)}ms")
IO.puts("  #{Float.round(per_call_us, 1)} μs/call")
IO.puts("  #{Float.round(calls_per_sec, 0)} calls/sec")

IO.puts("\n2. Name registry operations")
IO.puts("-" |> String.duplicate(40))

{elapsed_us, _} =
  :timer.tc(fn ->
    for i <- 1..1_000 do
      GaoBus.NameRegistry.name_has_owner?("com.test.Name#{i}")
    end
  end)

IO.puts("  1000 name lookups in #{Float.round(elapsed_us / 1_000, 1)}ms")
IO.puts("  #{Float.round(elapsed_us / 1_000, 1)} μs/lookup")

IO.puts("\n3. Multi-peer connect throughput")
IO.puts("-" |> String.duplicate(40))

peer_count = 20

{elapsed_us, conns} =
  :timer.tc(fn ->
    for _i <- 1..peer_count do
      BusBench.Helpers.connect_peer(socket_path)
    end
  end)

IO.puts("  #{peer_count} peers connected in #{Float.round(elapsed_us / 1_000, 1)}ms")
IO.puts("  #{Float.round(elapsed_us / 1_000 / peer_count, 1)} ms/connect")

IO.puts("\n4. ListNames with #{peer_count + 1} peers")
IO.puts("-" |> String.duplicate(40))

{elapsed_us, _} =
  :timer.tc(fn ->
    for _i <- 1..1_000 do
      GaoBus.NameRegistry.list_names()
    end
  end)

IO.puts("  1000 ListNames calls in #{Float.round(elapsed_us / 1_000, 1)}ms")
IO.puts("  #{Float.round(elapsed_us / 1_000, 1)} μs/call")

# Cleanup
for c <- conns do
  try do
    Connection.disconnect(c)
  catch
    _, _ -> :ok
  end
end

Connection.disconnect(conn)
Application.stop(:gao_bus)
File.rm(socket_path)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Benchmark complete.")
