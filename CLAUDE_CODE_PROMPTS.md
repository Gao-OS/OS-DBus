# Claude Code Prompts — gao_dbus

## Prompt 1: Scaffold the Umbrella

```
Read CLAUDE.md first. Then scaffold the gao_dbus Elixir umbrella project:

1. Create the umbrella root with `mix new gao_dbus --umbrella`
2. Create apps:
   - `cd apps && mix new ex_dbus` (library, no supervision)
   - `cd apps && mix new gao_bus --sup` (OTP application)
   - `cd apps && mix new gao_config --sup` (OTP application)
   - `cd apps && mix phx.new gao_bus_web --live --no-ecto --no-mailer` (Phoenix LiveView)
   - `cd apps && mix new gao_bus_test` (test-only app)

3. Configure dependencies in each app's mix.exs:
   - ex_dbus: ZERO umbrella deps
   - gao_bus: `{:ex_dbus, in_umbrella: true}`
   - gao_config: `{:ex_dbus, in_umbrella: true}`
   - gao_bus_web: `{:ex_dbus, in_umbrella: true}, {:gao_bus, in_umbrella: true}, {:phoenix, "~> 1.7"}, {:phoenix_live_view, "~> 1.0"}`
   - gao_bus_test: all umbrella deps + `{:stream_data, "~> 1.0", only: :test}`

4. Add shared dev deps to umbrella root: `{:credo, "~> 1.7"}, {:dialyxir, "~> 1.4"}, {:ex_doc, "~> 0.34"}`

5. Create devenv.nix with elixir 1.17, erlang 27, nodejs, dbus tools

6. Verify: `mix compile` succeeds with zero warnings

IMPORTANT: ex_dbus/mix.exs must have NO umbrella dependencies.
```

## Prompt 2: ex_dbus Wire Protocol — Types & Encoder

```
Read CLAUDE.md, focusing on the D-Bus Wire Protocol Reference section.

Implement the ex_dbus type system and encoder:

1. `lib/ex_dbus/wire/types.ex`:
   - Define the type mapping from D-Bus signatures to Elixir types
   - Signature parser: "a{sv}" → {:array, {:dict_entry, :string, :variant}}
   - Signature serializer: reverse direction
   - Type validation functions

2. `lib/ex_dbus/wire/encoder.ex`:
   - `encode(value, type, endianness \\ :little) :: iolist()`
   - Handle all basic types (byte, boolean, int16/32/64, uint16/32/64, double, string, object_path, signature)
   - Handle container types (array, struct, variant, dict_entry)
   - Correct alignment padding for each type
   - Use iolist accumulation, NOT binary concatenation

3. Tests for every type, including:
   - Alignment padding correctness
   - Endianness (little + big)
   - Edge cases: empty arrays, empty strings, nested containers
   - a{sv} (the most common D-Bus pattern)

Focus on correctness over performance. Use the alignment table from CLAUDE.md.
Binary pattern matching and iolist are mandatory.
```

## Prompt 3: ex_dbus Wire Protocol — Decoder

```
Read CLAUDE.md. Implement the decoder as the inverse of the encoder.

1. `lib/ex_dbus/wire/decoder.ex`:
   - `decode(binary, type, endianness \\ :little) :: {:ok, value, rest} | {:error, reason}`
   - Handle all types matching the encoder
   - Consume correct alignment padding
   - Return remaining binary after decoding

2. Property-based tests:
   - For every type: encode(value) |> decode() == value (roundtrip)
   - Use StreamData generators for arbitrary D-Bus values
   - Test with random endianness

3. `lib/ex_dbus/message.ex`:
   - Define Message struct: type, flags, serial, headers, body
   - `encode_message(message) :: iodata()`
   - `decode_message(binary) :: {:ok, message, rest} | {:error, reason}`
   - Header field encoding/decoding (destination, sender, interface, member, signature, etc.)

The decoder MUST use binary pattern matching, not `binary_part` or manual offset tracking.
```

## Prompt 4: ex_dbus Auth & Transport

```
Read CLAUDE.md auth and transport sections.

1. `lib/ex_dbus/auth/mechanism.ex` — behaviour:
   - `@callback init(opts) :: state`
   - `@callback handle_line(line, state) :: {:send, line, state} | {:ok, guid, state} | {:error, reason}`

2. `lib/ex_dbus/auth/external.ex` — EXTERNAL auth:
   - Sends uid as hex string
   - Handles OK/REJECTED responses
   - State machine: :init → :waiting_ok → :authenticated

3. `lib/ex_dbus/transport/behaviour.ex`:
   - `@callback connect(address) :: {:ok, transport} | {:error, reason}`
   - `@callback send(transport, iodata) :: :ok | {:error, reason}`
   - `@callback recv(transport) :: {:ok, data} | {:error, reason}`
   - `@callback close(transport) :: :ok`

4. `lib/ex_dbus/transport/unix_socket.ex`:
   - Connect to AF_UNIX SOCK_STREAM
   - Support abstract and filesystem paths
   - Parse D-Bus address format: "unix:path=/var/run/dbus/system_bus_socket"

5. `lib/ex_dbus/connection.ex` — GenServer:
   - Manages transport + auth lifecycle
   - States: :connecting → :authenticating → :connected
   - Assigns serial numbers to outgoing messages
   - Dispatches incoming messages to callers

Test auth against real dbus-daemon if available in dev environment.
```

## Prompt 5: gao_bus — Core Bus Daemon

```
Read CLAUDE.md gao_bus architecture section.

Implement the bus daemon core:

1. `lib/gao_bus/application.ex` — supervision tree as documented in CLAUDE.md

2. `lib/gao_bus/listener.ex`:
   - Listen on configurable unix socket path (default: /tmp/gao_bus_socket for dev)
   - Accept connections, start Peer under PeerSupervisor
   - Pass socket ownership to Peer process

3. `lib/gao_bus/peer.ex`:
   - GenServer per connected client
   - Handle auth handshake (delegate to ex_dbus auth)
   - Receive messages from socket, decode, forward to Router
   - Receive messages from Router, encode, send to socket
   - Auto-assign unique connection name (:1.N)

4. `lib/gao_bus/name_registry.ex`:
   - ETS-backed name → peer_pid mapping
   - RequestName / ReleaseName logic
   - NameOwnerChanged signals on ownership changes

5. `lib/gao_bus/router.ex`:
   - Route method_call to destination peer
   - Route method_return/error back to caller (by reply_serial)
   - Broadcast signals to all peers (match rules come later)
   - Handle messages to org.freedesktop.DBus (bus itself)

6. Implement org.freedesktop.DBus interface:
   - Hello() → assign unique name
   - RequestName(name, flags) → register well-known name
   - ReleaseName(name) → release
   - GetNameOwner(name) → lookup
   - ListNames() → all registered names

Integration test: start bus, connect two ex_dbus clients, send method_call from A to B, get response.
```

## Prompt 6: gao_bus_web — Phoenix LiveView Monitor

```
Read CLAUDE.md gao_bus_web section.

Implement the Phoenix LiveView D-Bus monitor:

1. Configure PubSub in gao_bus — broadcast events for:
   - :peer_connected / :peer_disconnected
   - :message_routed (every message through the bus)
   - :name_acquired / :name_released

2. `DashboardLive`:
   - Connected peers count (live counter)
   - Messages per second (rolling average)
   - Name registry table (live updates)
   - Bus uptime

3. `MessagesLive`:
   - Real-time message stream using LiveView streams
   - Filter by: sender, destination, interface, member, message type
   - Pause/resume button
   - Click message to expand full body with decoded types
   - Max buffer of 1000 messages (drop oldest)

4. `IntrospectLive`:
   - Tree view of all registered services
   - Click service → show objects → interfaces → methods/properties/signals
   - Uses D-Bus Introspectable interface

5. `CallLive`:
   - Select service → object → interface → method
   - Auto-generate input fields from method signature
   - Invoke button, show response

Use Tailwind for styling. LiveView streams for message list performance.
The PubSub integration is the key — gao_bus events flow to LiveView with zero overhead.
```

## Prompt 7: gao_config — System Config Service

```
Read CLAUDE.md gao_config section.

1. `lib/gao_config/application.ex`:
   - Start config store
   - Connect to gao_bus as a client using ex_dbus
   - Register org.gaoos.Config1 well-known name

2. `lib/gao_config/config_store.ex`:
   - ETS table for runtime config
   - Persistent storage to disk (DETS or :erlang.term_to_binary file)
   - get/set/delete/list operations
   - Change notification via PubSub

3. `lib/gao_config/dbus_interface.ex`:
   - Export as D-Bus object at /org/gaoos/Config1
   - Methods: Get(section, key), Set(section, key, value), Delete(section, key), List(section)
   - Signals: ConfigChanged(section, key, value)
   - Properties: Version (read-only)

4. Config provider behaviour for future extensibility:
   - Network, display, audio providers plug into the store

Test: start gao_bus + gao_config, use ex_dbus client to call Config1.Set(), verify Config1.Get() returns it.
```

## Usage

Use these prompts sequentially with Claude Code. Each prompt builds on the previous.
Start with Prompt 1, verify compilation, then proceed.
