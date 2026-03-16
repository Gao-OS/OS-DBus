# ADR-001: Pure Elixir Wire Protocol (No NIFs)

## Status
Accepted

## Context
The D-Bus wire protocol requires binary encoding/decoding with specific alignment rules. Options:
1. Pure Elixir using binary pattern matching
2. Rust NIF via Rustler wrapping `zbus`
3. C NIF wrapping `libdbus`

## Decision
Pure Elixir implementation.

## Rationale
- BEAM binary pattern matching is purpose-built for this workload
- Hot code upgrades work — NIFs block this for protocol changes
- No segfault risk from NIF bugs
- D-Bus wire format is straightforward (aligned fields, type signatures) — not compute-intensive enough to justify NIF overhead
- Keeps ex_dbus dependency-free and hex-publishable without native compilation

## Trade-offs
- **Pro**: Zero native dependencies, portable, hot-upgradable, debuggable
- **Con**: Potentially slower for high-throughput bulk encoding
- **Mitigation**: If benchmarks show bottleneck, specific hot paths can be optimized with manual binary construction without changing the API

## Alternatives Rejected
- **Rustler + zbus**: Adds build complexity, breaks hot upgrades, zbus is async-std which doesn't map to OTP
- **C NIF + libdbus**: libdbus is notoriously hard to use correctly, NIF crashes take down the BEAM VM
