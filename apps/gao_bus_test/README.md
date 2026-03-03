# GaoBusTest

Integration, interop, and property-based test suite for the `gao_dbus` umbrella
project. This app has no runtime code -- it exists solely to test the full stack
with all apps wired together.

## Test Categories

**Integration tests** -- start `gao_bus` and exercise end-to-end flows: peer
connection, authentication, name registration, method calls, signal delivery,
Unix FD passing, and capability-based policy enforcement.

**Interop tests** -- verify that real Linux D-Bus tools (`busctl`, `gdbus`,
`dbus-send`) can connect to and communicate with `gao_bus`. These tests are
tagged `@tag :interop` and excluded by default (they require the tools to be
installed on the host).

**Property-based tests** -- use StreamData to generate random D-Bus values and
verify encode-then-decode roundtrips for all wire protocol types, including
nested containers, variants, and edge cases.

## Running Tests

From the umbrella root:

```sh
mix test apps/gao_bus_test/test
```

To include interop tests (requires `busctl`, `gdbus`, and `dbus-send`):

```sh
mix test apps/gao_bus_test/test --include interop
```

Or from this directory:

```sh
mix test
mix test --include interop
```
