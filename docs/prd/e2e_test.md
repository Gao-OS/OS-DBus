# PRD: End-to-End Test Suite for Elixir D-Bus Package (v2)

## 1. Summary

A runnable E2E test suite that validates the Elixir D-Bus package as a real D-Bus participant — both client and service — using `dbus-daemon`, `busctl`, and `gdbus` in an isolated environment with deterministic CI-compatible output.

**Platform constraint:** Linux-only. The required tools (`dbus-daemon`, `busctl` from systemd, `gdbus` from GLib) are Linux-specific. macOS and Windows are explicitly unsupported.

---

## 2. Motivation

Internal unit/codec tests cannot prove real interoperability. The package must be validated against a real bus with real external tools, in both directions, across success and failure paths. Without this, release decisions are based on incomplete evidence.

---

## 3. Package Capability Baseline

The following table declares which D-Bus features the package currently supports. This resolves all "where supported" qualifiers in the scenario matrix.

| Feature                    | Status              | Notes                                           |
|----------------------------|---------------------|-------------------------------------------------|
| Bus connection             | ✅ Supported         |                                                 |
| Well-known name ownership  | ✅ Supported         |                                                 |
| Name release               | ✅ Supported         | `ReleaseName` is exposed                        |
| Method call (in/out)       | ✅ Supported         |                                                 |
| D-Bus error replies        | ✅ Supported         |                                                 |
| Signal emission            | ✅ Supported         |                                                 |
| Signal reception           | ✅ Supported         |                                                 |
| Match rules                | ✅ Supported         |                                                 |
| Introspection (expose)     | ✅ Supported         |                                                 |
| Introspection (consume)    | ✅ Supported         | Full parse: methods, signals, properties, args  |
| Properties (Get/Set/GetAll)| ❌ Not implemented   | Known gap — scenarios assert graceful absence   |
| PropertiesChanged signal   | ❌ Not implemented   | Known gap — scenarios assert graceful absence   |
| FD passing                 | ❌ Not implemented   | Out of scope for v1                             |

> Property scenarios (#11–#14) are **known-gap tests** in v1. They must assert that the package does not crash when properties are requested and produces a predictable unsupported-feature error. These scenarios become release-gate mandatory when property support is added.

---

## 4. Environment Specification

### 4.1 Nix devShell (mandatory)

The test environment must be declaratively reproducible via a Nix flake devShell.

```nix
# Required packages in devShell
{
  dbus          # provides dbus-daemon, dbus-launch
  systemd       # provides busctl (use systemdMinimal or lib subpackage)
  glib          # provides gdbus
  pkg-config    # for fixture compilation
  glib.dev      # GLib headers for C fixture service
  gcc           # or clang — fixture compiler
  # Elixir/OTP provided by project flake
}
```

The flake must pin all tool versions. CI runs inside `nix develop` or equivalent. The C fixture binary is compiled as a build step (e.g., `make -C test/fixture`) before the E2E suite runs.

### 4.2 Bus isolation

Each test run (or scenario group) spawns a private `dbus-daemon --session --nofork` with a generated config file and socket path under a temp directory. The `DBUS_SESSION_BUS_ADDRESS` env var is set per-run. No host bus is touched.

### 4.3 Cleanup

Bus daemon processes and temp socket files are cleaned up unconditionally via an `after` callback or trap, including on test crash.

---

## 5. Fixture Service Definition

Client-side tests (Elixir-to-external) require a well-defined external service fixture. This section specifies it.

### 5.1 Fixture identity

| Property        | Value                                         |
|-----------------|-----------------------------------------------|
| Bus name        | `com.test.ExternalFixture`                    |
| Object path     | `/com/test/ExternalFixture`                   |
| Interface       | `com.test.ExternalFixture`                    |
| Implementation  | C/GLib (`gio-2.0`) compiled binary            |
| Source location | `test/fixture/external_fixture.c`             |
| Build command   | `make -C test/fixture` (via `pkg-config --cflags --libs gio-2.0`) |

### 5.2 Fixture interface

```xml
<node>
  <interface name="com.test.ExternalFixture">
    <!-- Success path -->
    <method name="Echo">
      <arg direction="in" name="input" type="s"/>
      <arg direction="out" name="output" type="s"/>
    </method>

    <!-- Typed round-trip -->
    <method name="TypeRoundTrip">
      <arg direction="in" name="input" type="v"/>
      <arg direction="out" name="output" type="v"/>
    </method>

    <!-- Error path: always returns a D-Bus error -->
    <method name="AlwaysFail">
      <arg direction="in" name="input" type="s"/>
    </method>

    <!-- Slow path: sleeps N ms before replying (timeout testing) -->
    <method name="SlowEcho">
      <arg direction="in" name="delay_ms" type="u"/>
      <arg direction="in" name="input" type="s"/>
      <arg direction="out" name="output" type="s"/>
    </method>

    <!-- Signal emission on demand -->
    <method name="EmitTestSignal">
      <arg direction="in" name="payload" type="s"/>
    </method>

    <signal name="TestSignal">
      <arg name="payload" type="s"/>
    </signal>

    <!-- Properties: retained in fixture for future property support testing.
         Currently exercised only by known-gap scenarios (#11-#14). -->
    <property name="CurrentValue" type="s" access="readwrite"/>
  </interface>
</node>
```

### 5.3 Fixture lifecycle

The fixture is started per-scenario-group (not per-scenario) and killed after the group completes. It runs in the same private bus as the Elixir process under test.

### 5.4 Implementation: C/GLib

The fixture is a single-file C program using GLib's GDBus API (`gio-2.0`). This choice adds no extra runtime dependencies beyond what `gdbus` itself requires.

**Build requirements:** `gcc`, `pkg-config`, `glib.dev` (all provided by the Nix devShell).

**Compilation:**

```makefile
# test/fixture/Makefile
CFLAGS  := $(shell pkg-config --cflags gio-2.0)
LDFLAGS := $(shell pkg-config --libs gio-2.0)

external_fixture: external_fixture.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f external_fixture
```

**Binary interface contract:**

```
Usage: external_fixture [--bus-address ADDRESS]

Behavior:
  - Acquires com.test.ExternalFixture on the given bus
  - Exports the interface defined in §5.2
  - Echo: returns input unchanged
  - TypeRoundTrip: returns input variant unchanged
  - AlwaysFail: returns org.freedesktop.DBus.Error.Failed
  - SlowEcho: sleeps delay_ms then returns input
  - EmitTestSignal: emits TestSignal with given payload
  - Exits cleanly on SIGTERM
  - Prints "READY\n" to stdout after name acquisition (harness sync signal)
```

The `READY` stdout marker lets the Elixir harness synchronize — it waits for this line before running scenarios, avoiding startup races.

**Estimated size:** ~200–300 lines of C. The GDBus method dispatch is boilerplate-heavy but straightforward. The introspection XML from §5.2 is embedded as a string literal.

---

## 6. Scenario Matrix

All scenarios in one table. This replaces §16 from v1.

### Legend

- **Direction**: `E→X` = Elixir client → external service, `X→E` = external tool → Elixir service
- **Tools**: `bc` = busctl, `gd` = gdbus, `dd` = dbus-daemon, `fix` = fixture service
- **Gate**: `R` = release-gate mandatory, `KG` = known gap (assert no crash), `O` = optional/extended

### 6.1 Method calls

| # | Scenario                        | Dir  | Tools    | Gate | Assertion                                       |
|---|---------------------------------|------|----------|------|-------------------------------------------------|
| 1 | busctl calls Elixir method      | X→E  | bc       | R    | Correct return value in busctl stdout            |
| 2 | gdbus calls Elixir method       | X→E  | gd       | R    | Correct return value in gdbus stdout             |
| 3 | Elixir calls fixture Echo       | E→X  | fix      | R    | Elixir receives correct reply                    |
| 4 | Elixir calls fixture TypeRoundTrip (per type) | E→X | fix | R | Round-trip correctness for each supported type |
| 5 | busctl calls nonexistent method | X→E  | bc       | R    | D-Bus error returned to busctl                   |
| 6 | Elixir calls fixture AlwaysFail | E→X  | fix      | R    | Elixir receives structured D-Bus error           |

### 6.2 Signals

| # | Scenario                          | Dir  | Tools    | Gate | Assertion                                     |
|---|-----------------------------------|------|----------|------|-----------------------------------------------|
| 7 | Elixir emits signal, busctl observes | X→E | bc     | R    | Signal payload visible in busctl monitor       |
| 8 | Elixir emits signal, gdbus observes  | X→E | gd     | R    | Signal payload visible in gdbus monitor        |
| 9 | Fixture emits signal, Elixir receives | E→X | fix   | R    | Elixir callback invoked with correct payload   |
|10 | Signal with match rule filtering  | E→X  | fix      | R    | Only matched signals delivered to Elixir       |

### 6.3 Properties (known-gap — package does not implement properties)

| # | Scenario                             | Dir  | Tools | Gate | Assertion                                  |
|---|--------------------------------------|------|-------|------|--------------------------------------------|
|11 | busctl reads Elixir property         | X→E  | bc    | KG   | Predictable error (not crash)              |
|12 | gdbus sets Elixir property           | X→E  | gd    | KG   | Predictable error (not crash)              |
|13 | Elixir reads fixture property        | E→X  | fix   | KG   | Predictable error or not-implemented response |
|14 | PropertiesChanged observed externally| X→E  | bc/gd | KG   | No signal emitted (expected)               |

> `KG` = Known gap. These scenarios verify the package does not crash on property operations. They become `R` when property support is implemented.

### 6.4 Introspection

| # | Scenario                           | Dir  | Tools | Gate | Assertion                                   |
|---|------------------------------------|------|-------|------|--------------------------------------------|
|15 | busctl introspect Elixir service   | X→E  | bc    | R    | Valid XML, methods/signals present          |
|16 | gdbus introspect Elixir service    | X→E  | gd    | R    | Valid XML, consistent with busctl           |
|17 | Elixir introspects fixture         | E→X  | fix   | R    | Parsed structs match expected methods/signals/args |

### 6.5 Bus semantics

| # | Scenario                          | Dir  | Tools | Gate | Assertion                                    |
|---|-----------------------------------|------|-------|------|----------------------------------------------|
|18 | Name acquisition visible           | X→E  | bc    | R    | busctl shows well-known name owned           |
|19 | Name release                       | X→E  | bc    | R    | busctl shows name no longer owned after release |
|20 | Ownership change notification      | -    | bc    | O    | Ownership transfer observable                |

### 6.6 Error & failure paths

| # | Scenario                             | Dir  | Tools | Gate | Assertion                                    |
|---|--------------------------------------|------|-------|------|----------------------------------------------|
|21 | Elixir calls unavailable service     | E→X  | -     | R    | Predictable error within timeout budget      |
|22 | Elixir method call timeout           | E→X  | fix   | R    | Timeout error after defined budget           |
|23 | Peer termination mid-session         | E→X  | fix   | R    | Elixir handles disconnect without crash      |
|24 | Bus daemon termination               | -    | dd    | R    | Elixir detects disconnect, no orphan state   |
|25 | Invalid message / malformed request  | X→E  | bc    | R    | Error response, no crash                     |

### 6.7 Concurrency

| # | Scenario                              | Dir  | Tools | Gate | Assertion                                  |
|---|---------------------------------------|------|-------|------|--------------------------------------------|
|26 | Concurrent method calls from busctl   | X→E  | bc    | R    | All calls return correct results           |
|27 | Concurrent Elixir calls to fixture    | E→X  | fix   | R    | All replies correctly demuxed              |

---

## 7. Harness Architecture

### 7.1 Execution model

Scenarios execute **sequentially within a group**, groups execute **sequentially**. Each group gets a fresh bus daemon instance. This eliminates cross-scenario state leaks without requiring per-scenario bus spin-up overhead.

Rationale: D-Bus state (name ownership, subscriptions) leaks across scenarios on a shared bus. Group-level isolation is the minimum safe boundary.

### 7.2 Process lifecycle per group

```
0. Compile fixture binary (once per suite run, via `make -C test/fixture`)
1. Start dbus-daemon → capture socket address
2. Set DBUS_SESSION_BUS_ADDRESS
3. Start fixture service (if group needs E→X direction) → wait for "READY\n" on stdout
4. Start Elixir service under test (if group needs X→E direction)
5. For each scenario in group:
   a. Execute action (tool invocation or Elixir call)
   b. Capture stdout/stderr/exit code from external tools
   c. Capture Elixir-side observable result
   d. Evaluate assertions
   e. Record pass/fail + failure reason
6. Teardown: kill Elixir service, fixture (SIGTERM), dbus-daemon
7. Clean temp files
```

### 7.3 Tool invocation

External tools (`busctl`, `gdbus`) are invoked via `System.cmd/3` or `Port` with explicit timeouts. Stdout and stderr are captured for assertion evaluation. Exit codes are checked.

### 7.4 Parallelism (future)

The sequential model is required for v1. Future versions may parallelize groups by running each in its own bus instance (different socket paths). The architecture must not preclude this — no global mutable state in the harness.

---

## 8. Timeout Budgets

| Scope              | Budget    | Notes                                         |
|--------------------|-----------|-----------------------------------------------|
| Per tool invocation | 5s        | busctl/gdbus calls; fail-fast on hang         |
| Per scenario        | 15s       | Includes setup + action + teardown            |
| Per group           | 120s      | Hard kill on group if exceeded                |
| Full suite          | 600s      | CI hard-kills the job beyond this             |
| SlowEcho fixture    | configurable | Used to test Elixir-side timeout handling  |

Timeout scenarios (#22) use the fixture's `SlowEcho` with a delay exceeding the Elixir client's configured call timeout (e.g., fixture delays 5s, Elixir timeout is 2s).

---

## 9. ExUnit Integration

### 9.1 Tag strategy

```elixir
@moduletag :e2e
@tag group: :methods
@tag direction: :external_to_elixir
@tag gate: :release
```

### 9.2 Usage modes

| Mode                 | Command                                          |
|----------------------|--------------------------------------------------|
| Full suite           | `mix test --only e2e`                            |
| Single group         | `mix test --only e2e --only group:methods`       |
| Release gate         | `mix test --only e2e --only gate:release`        |
| Exclude E2E          | `mix test --exclude e2e` (default in `test_helper.exs`) |

E2E tests are **excluded by default** so `mix test` runs fast. The release gate is an explicit opt-in.

### 9.3 CI entry point

```yaml
# Example GitHub Actions step
- name: E2E Release Gate
  run: nix develop --command mix test --only e2e --only gate:release --max-failures 1
  timeout-minutes: 10
```

---

## 10. Outputs

| Output                | Format                    | Consumer        |
|-----------------------|---------------------------|-----------------|
| Per-scenario result   | ExUnit standard output    | Developer       |
| Group summary         | ExUnit tag-based grouping | Developer       |
| Suite pass/fail       | Process exit code (0/1)   | CI pipeline     |
| Failure detail        | ExUnit failure message    | Developer       |
| JUnit XML (optional)  | Via `junit_formatter`     | CI dashboards   |

---

## 11. Release Acceptance Gate

A release is **blocked** unless all `gate: :release` scenarios pass. The mandatory set:

- ✅ Bus connection established
- ✅ At least one X→E method call succeeds (busctl + gdbus)
- ✅ At least one E→X method call succeeds
- ✅ D-Bus errors emitted and received in both directions
- ✅ Signal delivery in both directions
- ✅ Introspection valid with both busctl and gdbus
- ✅ Elixir introspection consumption parses fixture correctly
- ✅ Name acquisition and release externally visible
- ✅ Timeout, unavailable-peer, and disconnect handled
- ✅ Concurrent calls correctly demuxed
- ✅ Property scenarios don't crash (known-gap assertions)
- ✅ Suite exit code is 0

---

## 12. Out of Scope (v1)

FD passing, `dbus-broker`, stress/chaos testing, desktop compatibility matrices, performance benchmarks, `dbus-monitor`/`dbus-send` integration.

---

## 13. Future Expansion

`dbus-broker` as alternate bus, `dbus-monitor` for trace capture, reconnection scenarios, broader type coverage, group-level parallelism, real-service interop targets (e.g., NetworkManager read-only queries), property support promotion (KG → R when implemented).

---

## 14. Resolved Decisions

All open questions from PRD v2 draft are now resolved:

| # | Question                        | Decision                                                              |
|---|----------------------------------|-----------------------------------------------------------------------|
| 1 | Fixture implementation language  | **C/GLib** (`gio-2.0`). No extra runtime. ~200-300 LOC. Build via Makefile with `pkg-config`. |
| 2 | Property support status          | **Not implemented.** Property scenarios (#11–#14) are known-gap tests asserting no-crash behavior. |
| 3 | Introspection consumption depth  | **Full parse.** Package extracts methods, signals, properties, and arg types into Elixir structs. Scenario #17 is release-gate mandatory. |
| 4 | Name release                     | **Supported.** `ReleaseName` is exposed. Scenario #19 is release-gate mandatory. |

No open questions remain. This PRD is implementation-ready.