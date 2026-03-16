# ADR-003: Capability-Based Security Policy

## Status
Accepted

## Context
dbus-daemon uses XML policy files for access control. Options:
1. Reimplement XML policy parsing (compatibility)
2. Capability-based Elixir policy modules (GaoOS-native)
3. Both (compat layer + native)

## Decision
Capability-based Elixir policy as primary, with optional XML compat layer.

## Rationale
- XML policy files are verbose, hard to test, and error-prone
- Capability-based security aligns with GaoOS's core architectural principle (no ambient authority)
- Elixir policy modules are testable, composable, and hot-upgradable
- The compat layer allows drop-in replacement of dbus-daemon without rewriting all service policy files immediately

## Design
Policy is a behaviour. The bus delegates every access decision to the active policy module:
- `allow_own?(peer, name)` — can this peer own this well-known name?
- `allow_send?(peer, message)` — can this peer send this message?
- `allow_receive?(peer, message)` — can this peer receive this message?

Capability policy: peers acquire capabilities (tokens) through an explicit grant mechanism. Policy rules reference capabilities, not uids/gids.

## Trade-offs
- **Pro**: Testable, composable, aligns with GaoOS vision, hot-upgradable
- **Con**: Existing Linux services expect XML policy — must support compat mode for adoption
- **Mitigation**: compat.ex parses XML policy files into the same behaviour interface
