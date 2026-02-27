defmodule GaoConfig.DBusInterface do
  @moduledoc """
  D-Bus object implementation for org.gaoos.Config1.

  Implements the `ExDBus.Object` behaviour so that `ExDBus.Object.dispatch/2`
  can route incoming method calls from BusClient.

  ## Methods

  - `Get(section: s, key: s) → value: s`
  - `Set(section: s, key: s, value: s)`
  - `Delete(section: s, key: s)`
  - `List(section: s) → entries: a{ss}`
  - `ListSections() → sections: as`
  - `GetVersion() → version: s`

  ## Signals

  - `ConfigChanged(section: s, key: s, value: s)`
  """

  @behaviour ExDBus.Object

  alias ExDBus.Introspection
  alias ExDBus.Introspection.{Method, Signal, Arg}

  @interface "org.gaoos.Config1"
  @version "0.1.0"

  @impl true
  def interfaces do
    [
      %Introspection{
        name: @interface,
        methods: [
          %Method{
            name: "Get",
            args: [
              %Arg{name: "section", type: "s", direction: :in},
              %Arg{name: "key", type: "s", direction: :in},
              %Arg{name: "value", type: "s", direction: :out}
            ]
          },
          %Method{
            name: "Set",
            args: [
              %Arg{name: "section", type: "s", direction: :in},
              %Arg{name: "key", type: "s", direction: :in},
              %Arg{name: "value", type: "s", direction: :in}
            ]
          },
          %Method{
            name: "Delete",
            args: [
              %Arg{name: "section", type: "s", direction: :in},
              %Arg{name: "key", type: "s", direction: :in}
            ]
          },
          %Method{
            name: "List",
            args: [
              %Arg{name: "section", type: "s", direction: :in},
              %Arg{name: "entries", type: "a{ss}", direction: :out}
            ]
          },
          %Method{
            name: "ListSections",
            args: [
              %Arg{name: "sections", type: "as", direction: :out}
            ]
          },
          %Method{
            name: "GetVersion",
            args: [
              %Arg{name: "version", type: "s", direction: :out}
            ]
          }
        ],
        signals: [
          %Signal{
            name: "ConfigChanged",
            args: [
              %Arg{name: "section", type: "s"},
              %Arg{name: "key", type: "s"},
              %Arg{name: "value", type: "s"}
            ]
          }
        ]
      }
    ]
  end

  @impl true
  def handle_method(@interface, "Get", [section, key]) do
    case GaoConfig.ConfigStore.get(section, key) do
      {:ok, value} ->
        {:ok, "s", [to_string(value)]}

      {:error, :not_found} ->
        {:error, "org.gaoos.Config1.Error.NotFound",
         "Key '#{key}' not found in section '#{section}'"}
    end
  end

  def handle_method(@interface, "Set", [section, key, value]) do
    :ok = GaoConfig.ConfigStore.set(section, key, value)
    {:ok, nil, []}
  end

  def handle_method(@interface, "Delete", [section, key]) do
    :ok = GaoConfig.ConfigStore.delete(section, key)
    {:ok, nil, []}
  end

  def handle_method(@interface, "List", [section]) do
    entries = GaoConfig.ConfigStore.list(section)
    pairs = Enum.map(entries, fn {k, v} -> {to_string(k), to_string(v)} end)
    {:ok, "a{ss}", [pairs]}
  end

  def handle_method(@interface, "ListSections", []) do
    sections = GaoConfig.ConfigStore.list_sections()
    {:ok, "as", [sections]}
  end

  def handle_method(@interface, "GetVersion", []) do
    {:ok, "s", [@version]}
  end

  def handle_method(_interface, method, _args) do
    {:error, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method: #{method}"}
  end

  @impl true
  def get_property(@interface, "Version") do
    {:ok, "s", @version}
  end

  def get_property(_interface, property) do
    {:error, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown property: #{property}"}
  end
end
