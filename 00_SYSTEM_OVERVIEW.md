# 00 — System Overview

## What This Is

gao_dbus replaces the Linux D-Bus system with a BEAM-native implementation. Instead of `dbus-daemon` (a C process that routes messages between Linux services), we run an Elixir OTP application that IS the message bus.

## Why This Exists

D-Bus is the IPC backbone of every modern Linux desktop and many embedded systems. NetworkManager, BlueZ, systemd-logind, PulseAudio — they all communicate via D-Bus. But `dbus-daemon` has fundamental limitations:

1. **Single process, no supervision** — if it crashes, the entire system IPC goes down
2. **XML security policy** — static, verbose, hard to reason about
3. **No hot upgrades** — updating the bus requires restarting all connected services
4. **Opaque to debugging** — `dbus-monitor` is the best tool, and it's primitive

By implementing the bus in Elixir/OTP:

1. **Every peer connection is supervised** — one client crash doesn't affect others
2. **Security policy is Elixir code** — capability-based, composable, testable
3. **Hot code upgrades** — update the bus without disconnecting clients
4. **Real-time web debugging** — Phoenix LiveView shows every message in the browser

## Where This Fits in GaoOS

gao_dbus is shared infrastructure across GaoOS Linux branches:

- **NervesOS branch**: gao_bus runs as PID 1's bus, BEAM services are first-class
- **StrataOS branch**: gao_bus replaces dbus-daemon under systemd
- **NixOS branch**: gao_bus packaged as a Nix service

The D-Bus interface becomes the common API surface that all GaoOS variants share, regardless of their init system or deployment model.

## Design Philosophy

1. **Protocol purity in ex_dbus** — the library implements D-Bus wire protocol with zero opinions about bus architecture. Anyone can use it for any D-Bus client/server need.

2. **Bus opinions in gao_bus** — the daemon makes opinionated choices about supervision, routing, and security. These are GaoOS-specific.

3. **Functional core, imperative shell** — wire protocol encode/decode are pure functions. GenServers exist only where state management requires them (peer connections, name registry, routing).

4. **BEAM as the advantage** — we don't fight the BEAM, we leverage it. Message passing IS the routing mechanism. Supervision IS the reliability model. ETS IS the name registry.
