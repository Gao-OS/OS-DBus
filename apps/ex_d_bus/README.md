# ExDBus

[![Hex.pm](https://img.shields.io/hexpm/v/ex_d_bus.svg)](https://hex.pm/packages/ex_d_bus)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ex_d_bus)
[![CI](https://github.com/Gao-OS/OS-DBus/actions/workflows/ci.yml/badge.svg)](https://github.com/Gao-OS/OS-DBus/actions/workflows/ci.yml)

Pure Elixir D-Bus wire protocol implementation with no C dependencies or NIFs.

ExDBus handles encoding/decoding of all D-Bus types, message framing,
authentication, and transport — suitable for both client and server use cases.

## Features

- Complete D-Bus wire protocol (all 13 types, both endianness)
- Binary pattern matching for decode, iolist for encode (zero-copy)
- EXTERNAL and ANONYMOUS authentication mechanisms
- Unix socket and TCP transports
- Client proxy and server object behaviours
- Introspection XML generation and parsing
- Hot-upgradable — no NIF segfaults, no C toolchain required

## Installation

Add `ex_d_bus` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_d_bus, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Connect to the system bus
{:ok, conn} = ExDBus.Connection.start_link(
  address: "unix:path=/var/run/dbus/system_bus_socket",
  auth_mod: ExDBus.Auth.External,
  owner: self()
)

# Wait for connection
receive do
  {:ex_d_bus, {:connected, _guid}} -> :ok
end

# Call a method
msg = ExDBus.Message.method_call(
  "/org/freedesktop/DBus",
  "org.freedesktop.DBus",
  "ListNames",
  destination: "org.freedesktop.DBus"
)

{:ok, reply} = ExDBus.Connection.call(conn, msg, 5_000)
[names] = reply.body
```

## Modules

| Module | Description |
|---|---|
| `ExDBus.Connection` | GenServer managing a single bus connection lifecycle |
| `ExDBus.Message` | Message struct with encode/decode for all 4 message types |
| `ExDBus.Proxy` | Client-side proxy for calling remote D-Bus objects |
| `ExDBus.Object` | Server-side behaviour for exporting Elixir modules as D-Bus objects |
| `ExDBus.Introspection` | XML introspection generation and parsing |
| `ExDBus.Wire.Encoder` | Elixir terms to D-Bus binary |
| `ExDBus.Wire.Decoder` | D-Bus binary to Elixir terms |
| `ExDBus.Wire.Types` | Type signature parsing, validation, alignment |

## License

Apache-2.0 — see [LICENSE](LICENSE).
