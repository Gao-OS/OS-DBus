defmodule ExDBus do
  @moduledoc """
  Pure Elixir D-Bus protocol implementation.

  ExDBus provides a complete D-Bus wire protocol library with no C dependencies
  or NIFs. It handles encoding/decoding of all D-Bus types, message framing,
  authentication, and transport — making it suitable for both client and server
  use cases.

  ## Main Modules

  - `ExDBus.Connection` — GenServer managing a single bus connection lifecycle
  - `ExDBus.Message` — Message struct with encode/decode for all 4 message types
  - `ExDBus.Proxy` — Client-side proxy for calling remote D-Bus objects
  - `ExDBus.Object` — Server-side behaviour for exporting Elixir modules as D-Bus objects
  - `ExDBus.Introspection` — XML introspection generation and parsing

  ## Wire Protocol

  - `ExDBus.Wire.Encoder` — Elixir terms to D-Bus binary (iolist, zero-copy)
  - `ExDBus.Wire.Decoder` — D-Bus binary to Elixir terms (binary pattern matching)
  - `ExDBus.Wire.Types` — Type signature parsing, validation, alignment

  ## Transport & Auth

  - `ExDBus.Transport.UnixSocket` — AF_UNIX SOCK_STREAM transport
  - `ExDBus.Transport.Tcp` — TCP transport for remote debugging
  - `ExDBus.Auth.External` — EXTERNAL auth (uid-based)
  - `ExDBus.Auth.Anonymous` — ANONYMOUS auth (for testing)

  ## Quick Start

      # Connect to a bus
      {:ok, conn} = ExDBus.Connection.start_link(
        address: "unix:path=/var/run/dbus/system_bus_socket",
        auth_mod: ExDBus.Auth.External,
        owner: self()
      )

      # Call a method via proxy
      proxy = ExDBus.Proxy.new(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus")
      {:ok, reply} = ExDBus.Proxy.call(proxy, "org.freedesktop.DBus", "ListNames")
  """
end
