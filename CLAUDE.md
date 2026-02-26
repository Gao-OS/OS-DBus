# CLAUDE.md — gao_dbus

## Project Context

**gao_dbus** is an Elixir umbrella project that implements the D-Bus protocol and a BEAM-native bus daemon. It is part of the GaoOS ecosystem — an umbrella OS project with variants including StrataOS, NixOS, LineageOS, RockNix, and NervesOS branches.

The core thesis: replace `dbus-daemon` (C, single process, no supervision) with a BEAM-based bus where every D-Bus message is an Erlang message, every connected peer is a supervised GenServer, and security policy is capability-based Elixir code instead of XML files.

## Umbrella Apps

```
gao_dbus/
├── apps/
│   ├── ex_dbus/          ← D-Bus protocol library (client + server, hex-publishable)
│   ├── gao_bus/          ← Bus daemon application (replaces dbus-daemon)
│   ├── gao_config/       ← org.gaoos.Config1 system config service
│   ├── gao_bus_web/      ← Phoenix LiveView monitor/debugger
│   └── gao_bus_test/     ← Integration & compliance tests
```

### Dependency Graph (MUST remain acyclic)

```
ex_dbus          ← ZERO umbrella deps, standalone hex package
    ↑
gao_bus          ← depends on ex_dbus
    ↑
gao_config       ← depends on ex_dbus (connects to gao_bus as client)
    ↑
gao_bus_web      ← depends on ex_dbus + gao_bus + phoenix
    ↑
gao_bus_test     ← depends on all apps
```

**CRITICAL**: `ex_dbus` MUST have zero umbrella dependencies. It must compile and work standalone. This enables future extraction to its own repo and publishing to Hex.

## Architecture Overview

### ex_dbus — D-Bus Protocol Library

Pure Elixir implementation of the D-Bus wire protocol (no C dependencies, no NIFs).

```
ex_dbus/lib/ex_dbus/
├── wire/
│   ├── encoder.ex        — Elixir terms → D-Bus binary (little/big endian)
│   ├── decoder.ex        — D-Bus binary → Elixir terms
│   └── types.ex          — D-Bus type signatures ↔ Elixir type mapping
├── auth/
│   ├── mechanism.ex      — Auth behaviour
│   ├── external.ex       — EXTERNAL auth (uid-based, primary)
│   └── anonymous.ex      — ANONYMOUS auth (for testing)
├── transport/
│   ├── behaviour.ex      — Transport behaviour
│   ├── unix_socket.ex    — AF_UNIX SOCK_STREAM
│   └── tcp.ex            — TCP transport (for remote GaoOS debugging)
├── message.ex            — Message struct: method_call, method_return, error, signal
├── connection.ex         — GenServer: single bus connection lifecycle
├── proxy.ex              — Client-side: object proxy (like GDBusProxy)
├── object.ex             — Server-side: behaviour for exporting objects
├── introspection.ex      — Generate/parse introspection XML
└── address.ex            — Parse D-Bus address strings
```

**Design decisions:**
- Pure Elixir wire protocol — hot-upgradable, no NIF segfaults
- One `Connection` GenServer per bus connection
- `Proxy` wraps a remote object for ergonomic client calls
- `Object` behaviour for exporting Elixir modules as D-Bus objects
- Binary pattern matching for decode, iolist for encode (zero-copy where possible)

### gao_bus — Bus Daemon

Replaces `dbus-daemon`. Listens on `/var/run/dbus/system_bus_socket`.

```
gao_bus/lib/gao_bus/
├── application.ex        — OTP app entry, top supervisor
├── listener.ex           — Accept connections on bus socket (GenServer)
├── peer.ex               — One GenServer per connected client (supervised)
├── peer_supervisor.ex    — DynamicSupervisor for peer processes
├── router.ex             — Message routing: unicast, broadcast, match rules
├── name_registry.ex      — Well-known name ownership (ETS-backed)
├── match_rules.ex        — Signal subscription filtering (ets match specs)
├── policy/
│   ├── behaviour.ex      — Policy behaviour
│   ├── capability.ex     — GaoOS capability-based access control
│   └── compat.ex         — Optional: parse legacy dbus XML policy files
├── introspect.ex         — Auto-generate bus introspection
└── pubsub.ex             — Internal PubSub for web monitor integration
```

**Supervision tree:**
```
GaoBus.Supervisor (one_for_one)
├── Registry (GaoBus.PeerRegistry)
├── GaoBus.NameRegistry (GenServer, ETS owner)
├── GaoBus.MatchRules (GenServer, ETS owner)
├── GaoBus.Router (GenServer)
├── GaoBus.PeerSupervisor (DynamicSupervisor)
│   ├── GaoBus.Peer (per connection)
│   ├── GaoBus.Peer (per connection)
│   └── ...
├── GaoBus.Listener (GenServer, accepts connections)
└── Phoenix.PubSub (for web monitor)
```

### gao_config — System Config Service

Registers `org.gaoos.Config1` on the bus. Manages system configuration with capability-gated access.

```
gao_config/lib/gao_config/
├── application.ex        — Connects to gao_bus, registers service
├── config_store.ex       — Persistent config storage (ETS + disk)
├── providers/
│   ├── behaviour.ex      — Config provider behaviour
│   ├── network.ex        — Network configuration
│   ├── display.ex        — Display/graphics settings
│   └── audio.ex          — Audio configuration
└── dbus_interface.ex     — org.gaoos.Config1 interface definition
```

### gao_bus_web — Phoenix LiveView Monitor

Real-time D-Bus inspector in the browser.

**LiveView pages:**
- `DashboardLive` — Peer count, message throughput, name registry, bus health
- `MessagesLive` — Real-time filtered message stream (Wireshark for D-Bus)
- `IntrospectLive` — Tree view of registered objects/interfaces/methods
- `CallLive` — Interactive method caller (select service → object → method → invoke)
- `CapabilitiesLive` — Capability policy viewer and access denial audit log

**Integration:** LiveView subscribes to `GaoBus.PubSub` — same BEAM VM, zero serialization overhead.

### gao_bus_test — Integration & Compliance Tests

- Compliance suite: verify gao_bus against `busctl`, `gdbus`, `dbus-send`
- Interop tests: real Linux D-Bus clients connecting to gao_bus
- Benchmarks: latency/throughput vs `dbus-daemon` and `dbus-broker`
- Property-based: encode→decode roundtrip with StreamData

## D-Bus Wire Protocol Reference

### Message Format
```
Header (fixed):
  byte        endianness ('l' = little, 'B' = big)
  byte        message_type (1=method_call, 2=method_return, 3=error, 4=signal)
  byte        flags (0x1=no_reply_expected, 0x2=no_auto_start)
  byte        protocol_version (1)
  uint32      body_length
  uint32      serial
  array       header_fields (typed key-value pairs)
  padding     align to 8 bytes

Body:
  [marshalled values according to signature]
```

### Type System Mapping
```
D-Bus Type    Signature   Elixir Type           Notes
─────────────────────────────────────────────────────────
BYTE          y           integer (0..255)
BOOLEAN       b           boolean
INT16         n           integer
UINT16        q           integer
INT32         i           integer
UINT32        u           integer
INT64         x           integer
UINT64        t           integer
DOUBLE        d           float
STRING        s           String.t()
OBJECT_PATH   o           String.t()            validated path format
SIGNATURE     g           String.t()            validated signature
ARRAY         a{type}     list()
STRUCT        ({types})   tuple()
VARIANT       v           {signature, value}    tagged union
DICT_ENTRY    {kv}        map() (when in array) a{sv} → %{String.t() => {sig, val}}
UNIX_FD       h           integer (fd number)   requires SCM_RIGHTS
```

### Alignment Rules
```
Type       Alignment (bytes)
BYTE       1
BOOLEAN    4
INT16      2
UINT16     2
INT32      4
UINT32     4
INT64      8
UINT64     8
DOUBLE     8
STRING     4 (for length prefix)
ARRAY      4 (for length prefix)
STRUCT     8
VARIANT    1
DICT_ENTRY 8
```

### Authentication Protocol
```
Client → Server:  \0                       (null byte)
Client → Server:  AUTH EXTERNAL <uid_hex>  (hex-encoded uid)
Server → Client:  OK <server_guid>
Client → Server:  BEGIN
[switch to binary protocol]
```

## Implementation Phases

### Phase 1 — Minimum Viable Bus
- [ ] Wire protocol: encode/decode all types with alignment
- [ ] AUTH EXTERNAL mechanism
- [ ] Message routing: unicast (method_call → method_return/error)
- [ ] Name ownership: RequestName, ReleaseName
- [ ] org.freedesktop.DBus interface on the bus itself
- [ ] Signal broadcasting (no match rules yet)

### Phase 2 — Real-World Compatibility
- [ ] Match rules for signal filtering
- [ ] Introspection (org.freedesktop.DBus.Introspectable)
- [ ] Properties interface (org.freedesktop.DBus.Properties)
- [ ] Unix FD passing (SCM_RIGHTS)
- [ ] Interop test: `busctl`, `gdbus`, `dbus-send` work against gao_bus

### Phase 3 — GaoOS Integration
- [ ] Capability-based policy engine
- [ ] org.gaoos.Config1 service
- [ ] Phoenix web monitor (all LiveView pages)
- [ ] TCP transport for remote debugging
- [ ] Integration with NetworkManager, BlueZ

### Phase 4 — Production Readiness
- [ ] Benchmarks vs dbus-daemon and dbus-broker
- [ ] Nerves firmware integration
- [ ] OTA update support
- [ ] Distributed bus (multi-node BEAM clustering)

## Code Conventions

### Naming
- `ExDBus.*` for library, `GaoBus.*` for daemon, `GaoConfig.*` for config, `GaoBusWeb.*` for Phoenix
- GenServers named after role: `Router`, `Listener`, `Peer` (not `RouterServer`)
- Test modules mirror source structure

### Patterns
- **Functional core, imperative shell** — pure functions for wire protocol, GenServers only for stateful coordination
- **Behaviours for extensibility** — transport, auth, policy, config provider
- **Binary pattern matching** for decoding — leverage BEAM's strength
- **iolist for encoding** — avoid binary concatenation, let the runtime flatten
- **`{:ok, result}` / `{:error, reason}`** for expected failures
- **Let it crash** for unexpected states — supervisor restarts

### Common Mistakes to Avoid

❌ NEVER store bus state in ex_dbus — it's a stateless protocol library
❌ NEVER block Peer GenServer on synchronous socket writes
❌ NEVER add umbrella deps to ex_dbus/mix.exs
❌ NEVER use string concatenation for binary protocol work
✅ ALWAYS use binary pattern matching for decode
✅ ALWAYS use iolist for encode
✅ ALWAYS test encode→decode roundtrip for every type
✅ ALWAYS supervise peer connections under DynamicSupervisor

## Development Environment

```nix
# Required in devenv.nix / flake.nix
- elixir 1.17+
- erlang/OTP 27+
- nodejs (Phoenix assets)
- dbus (for interop testing: dbus-send, dbus-monitor, busctl)
- socat (unix socket debugging)
```

## Deployment Modes

| Mode | Apps Running | Use Case |
|---|---|---|
| `full` | gao_bus + gao_config + gao_bus_web | Development |
| `headless` | gao_bus + gao_config | Production NervesOS |
| `monitor` | gao_bus_web (remote connect) | Remote debugging |
| `library` | ex_dbus only | Third-party package |
