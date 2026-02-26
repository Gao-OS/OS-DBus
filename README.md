# gao_dbus

A BEAM-native D-Bus implementation for GaoOS — replacing `dbus-daemon` with a supervised, capability-aware Elixir bus.

## Overview

gao_dbus is an Elixir umbrella project providing a complete D-Bus ecosystem:

- **ex_dbus** — Pure Elixir D-Bus protocol library (client + server)
- **gao_bus** — Bus daemon that replaces `dbus-daemon` with OTP supervision
- **gao_config** — System configuration service (`org.gaoos.Config1`)
- **gao_bus_web** — Phoenix LiveView real-time D-Bus monitor/debugger
- **gao_bus_test** — Integration, compliance, and interop test suite

Part of the [GaoOS](https://github.com/Gao-OS) ecosystem.

## Why

`dbus-daemon` is a C singleton — no supervision, no hot upgrades, XML security policy. By reimplementing the bus in Elixir:

- Every connected peer is a supervised GenServer (crash isolation)
- Every D-Bus message is an Erlang message (zero translation for BEAM services)
- Security policy is Elixir code with capability-based access control
- Real-time web debugging via Phoenix LiveView
- Hot code upgrades for the bus itself

## Quick Start

```bash
# Clone
git clone https://github.com/Gao-OS/gao_dbus.git
cd gao_dbus

# Setup (with devenv/nix)
devenv shell

# Dependencies
mix deps.get

# Test
mix test

# Run full stack (bus + config + web monitor)
mix phx.server
# Visit http://localhost:4000 for D-Bus monitor
```

## Architecture

```
ex_dbus (zero deps, hex-publishable)
    ↑
gao_bus (bus daemon)
    ↑
gao_config (system config service)
    ↑
gao_bus_web (Phoenix monitor)
    ↑
gao_bus_test (compliance suite)
```

## Development

See [CLAUDE.md](./CLAUDE.md) for comprehensive architecture documentation and AI development guide.

## License

Apache-2.0
