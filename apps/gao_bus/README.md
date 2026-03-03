# GaoBus

BEAM-native D-Bus bus daemon that replaces `dbus-daemon`. Every connected peer
is a supervised GenServer, every D-Bus message is an Erlang message, and security
policy is capability-based Elixir code instead of XML files.

Listens on a Unix socket (default `/var/run/dbus/system_bus_socket`) and
implements the `org.freedesktop.DBus` bus interface.

## Key Modules

- `GaoBus.Listener` -- accepts connections on the bus socket using Erlang `:socket`
- `GaoBus.Peer` -- one GenServer per connected client; async I/O with `recvmsg/sendmsg` and SCM_RIGHTS for Unix FD passing
- `GaoBus.PeerSupervisor` -- DynamicSupervisor for all peer processes
- `GaoBus.Router` -- unicast method calls, broadcast signals, policy enforcement
- `GaoBus.NameRegistry` -- ETS-backed well-known name ownership (RequestName/ReleaseName/queuing)
- `GaoBus.MatchRules` -- signal subscription filtering using ETS match specs
- `GaoBus.Policy.Capability` -- capability-based access control (send, receive, own)
- `GaoBus.Cluster` -- multi-node BEAM clustering via `:pg` for distributed bus routing
- `GaoBus.BusInterface` -- implements `org.freedesktop.DBus` (Hello, RequestName, ListNames, AddMatch, etc.)

## Running Tests

From the umbrella root:

```sh
mix test apps/gao_bus/test
```

Or from this directory:

```sh
mix test
```
