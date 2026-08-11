# OS-Bus E2E Conformance Harness

## Goals

The E2E harness is being refactored from a dbus-daemon-specific integration harness into a backend-agnostic conformance suite. Each scenario should express D-Bus semantics once and later run against both the reference `dbus-daemon` backend and `gao_bus`.

The first batch keeps the existing E2E tests working through `GaoBusTest.E2EHarness` while introducing new backend, actor, command, diagnostics, and oracle layers under `apps/gao_bus_test/test/support/e2e`.

## Concepts

- Backend: an isolated bus implementation with `start/1`, `address/1`, protocol `probe/1`, `diagnostics/1`, and idempotent `stop/1`.
- Actor: a client or service participating in a scenario, such as ExDBus, the GLib fixture, the Elixir service, `busctl`, or `gdbus`.
- Scenario: a tagged ExUnit test with a stable `e2e_id`, group, gate, supported backends, and actor requirements.
- Gate: a run scope selected by `E2E_GATE`. `smoke` runs the minimum protocol checks, `release` runs broader compatibility checks, and `all` includes every migrated scenario.
- Oracle: normalized semantic assertions for method returns, D-Bus errors, and signals. Tool text parsing is centralized here instead of spread across tests.

## Backends

- `reference`: starts a private `dbus-daemon` using an isolated temp directory, generated session config, and private Unix socket. Startup includes an ExDBus protocol probe: connect, `Hello`, and `ListNames`.
- `gao_bus`: starts the singleton `:gao_bus` application on an isolated private Unix socket per scenario by temporarily swapping `:gao_bus, :socket_path`, probing the D-Bus protocol, then restoring the previous app/env state on stop.

Backend availability is probed once per E2E test run from `test_helper.exs`, before test files load. Results are cached in `:persistent_term` so per-test skip tags never restart global apps or spawn daemon processes during parallel test-file loading.

## Diagnostics

On failure, or when `E2E_KEEP_ARTIFACTS=1`, diagnostics are written under:

```text
_build/test/e2e_artifacts/<scenario_id>/<backend>/<unique_id>/
```

Artifacts include:

- `context.json`: scenario/backend metadata.
- `backend.log`: backend diagnostics and captured daemon output when available.
- `fixture.log`: GLib fixture output when that actor is used.
- `commands.jsonl`: process-scoped command results emitted by `busctl`/`gdbus` wrappers.

## Known Gaps

Unavailable tools or unsupported backend features must be explicit. A missing `dbus-daemon`, missing GLib fixture binary, missing `busctl`/`gdbus`, or a backend startup/probe failure is reported as a skip/known gap in migrated scenarios. Tests should not silently pass when an actor or backend is absent.

Scenarios can tag backend-specific known gaps with `known_gap: [:gao_bus]`. When a selected backend is listed in `known_gap`, that backend is omitted for the scenario. If every selected backend is omitted, the scenario is skipped with a known-gap reason pointing to `docs/e2e-matrix.md`. With `E2E_BACKEND=both`, non-gap backends still run normally.

Known-gap tags are constrained:

- `known_gap` must never include `:reference`.
- `gate: :smoke` scenarios must not carry a `known_gap` tag.

Every known-gap matrix entry must include a diagnosis, not just a label.

## How To Run

Run non-E2E tests:

```sh
mix test --exclude e2e
```

Run migrated smoke scenarios against the reference backend:

```sh
E2E_BACKEND=reference E2E_GATE=smoke mix test --only e2e
```

Run smoke scenarios against the gao_bus backend:

```sh
E2E_BACKEND=gao_bus E2E_GATE=smoke mix test --only e2e
```

Build the GLib fixture when GLib and pkg-config are available:

```sh
make -C apps/gao_bus_test/test/fixture
```

Keep diagnostics even for passing scenarios:

```sh
E2E_KEEP_ARTIFACTS=1 E2E_BACKEND=reference E2E_GATE=all mix test --only e2e
```

## CI Policy

Pull requests run the required conformance matrix across:

- backends: `reference`, `gao_bus`
- gates: `smoke`, `release`

All four PR jobs are required and fail normally. Known gaps are represented by scenario tags and explicit skips, so a red `gao_bus` job is treated as a regression.

Nightly CI runs the `compat` gate for both backends at 03:00 UTC. Manual `workflow_dispatch` runs can select a single gate (`smoke`, `release`, `compat`, `stress`, or `all`) and run it against both backends.

CI runs E2E tests with `E2E_KEEP_ARTIFACTS=1`. On failure, GitHub Actions uploads the generated `e2e_artifacts` directory so `context.json`, `backend.log`, `fixture.log`, and `commands.jsonl` are available for debugging.
