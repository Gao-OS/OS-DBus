# ADR-002: Umbrella Project Structure

## Status
Accepted

## Context
Five related apps need to be developed together: protocol library, bus daemon, config service, web monitor, integration tests. Options:
1. Umbrella app (shared repo, in_umbrella deps)
2. Dave Thomas multi-app (separate mix.exs, path deps)
3. Separate repos with version pinning

## Decision
Umbrella app with strict acyclic dependency constraint.

## Rationale
- Single developer, tightly coupled iteration — protocol changes need immediate bus testing
- ex_dbus maintains zero umbrella deps (extractable to standalone repo at any point)
- Single devenv.nix, single CI pipeline
- Integration tests can depend on all apps naturally

## Constraints
- ex_dbus MUST have zero umbrella deps — enforced by CI
- Dependency direction must remain acyclic: ex_dbus → gao_bus → gao_config → gao_bus_web → gao_bus_test
- When ex_dbus API stabilizes, extract to separate repo and switch to hex dependency

## Alternatives Rejected
- **Separate repos**: PR ping-pong and version coordination overhead for no benefit during active development
- **Dave Thomas path deps**: Functionally identical to umbrella for this case, but umbrella has better tooling support (mix test from root runs all apps)
