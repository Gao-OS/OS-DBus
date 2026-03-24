# GaoConfig

D-Bus service that registers `org.gaoos.Config1` on the bus and provides
system configuration management for GaoOS. Connects to `gao_bus` as a
standard D-Bus client using `ex_d_bus`.

Configuration data is stored in ETS with disk persistence, organized into
sections and key-value pairs.

## D-Bus Interface

Object path: `/org/gaoos/Config1`

Methods:

- `Get(section, key)` -- retrieve a single config value
- `Set(section, key, value)` -- write a config value
- `Delete(section, key)` -- remove a config value
- `List(section)` -- list all keys in a section
- `ListSections()` -- list all config sections
- `GetVersion()` -- return the config service version

Signals:

- `ConfigChanged(section, key, value)` -- emitted on every Set or Delete

## Key Modules

- `GaoConfig.BusClient` -- connects to `gao_bus`, registers the well-known name
- `GaoConfig.ConfigStore` -- ETS-backed persistent config storage
- `GaoConfig.DBusInterface` -- `ExDBus.Object` implementation that handles method dispatch

## Running Tests

From the umbrella root:

```sh
mix test apps/gao_config/test
```

Or from this directory:

```sh
mix test
```
