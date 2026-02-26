defmodule ExDBus.Introspection do
  @moduledoc """
  D-Bus introspection XML generation and parsing.

  Generates standard D-Bus introspection XML from interface definitions,
  and parses introspection XML into structured data.
  """

  @doc """
  An interface definition with methods, signals, and properties.
  """
  defstruct name: nil, methods: [], signals: [], properties: []

  defmodule Method do
    @moduledoc false
    defstruct name: nil, args: []
  end

  defmodule Signal do
    @moduledoc false
    defstruct name: nil, args: []
  end

  defmodule Property do
    @moduledoc false
    defstruct name: nil, type: nil, access: :read
  end

  defmodule Arg do
    @moduledoc false
    defstruct name: nil, type: nil, direction: nil
  end

  @doc """
  Generate introspection XML for a node.

  ## Parameters
    - `path` - The object path
    - `interfaces` - List of `%ExDBus.Introspection{}` structs
    - `child_nodes` - List of child node name strings (optional)

  ## Example

      iex> iface = %ExDBus.Introspection{
      ...>   name: "com.example.Foo",
      ...>   methods: [
      ...>     %ExDBus.Introspection.Method{
      ...>       name: "Bar",
      ...>       args: [
      ...>         %ExDBus.Introspection.Arg{name: "input", type: "s", direction: :in},
      ...>         %ExDBus.Introspection.Arg{name: "output", type: "s", direction: :out}
      ...>       ]
      ...>     }
      ...>   ]
      ...> }
      iex> xml = ExDBus.Introspection.to_xml("/com/example", [iface])
      iex> String.contains?(xml, "<interface name=\\"com.example.Foo\\">")
      true
  """
  def to_xml(path, interfaces, child_nodes \\ []) do
    [
      ~s(<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"\n),
      ~s( "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">\n),
      ~s(<node name="#{escape_xml(path)}">\n),
      Enum.map(interfaces, &interface_to_xml/1),
      Enum.map(child_nodes, &child_node_to_xml/1),
      "</node>\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  Parse introspection XML into structured data.

  Returns `{:ok, path, interfaces, child_nodes}` or `{:error, reason}`.
  """
  def from_xml(xml) when is_binary(xml) do
    case parse_node(xml) do
      {:ok, _path, _interfaces, _children} = result -> result
      {:error, _} = error -> error
    end
  end

  @doc """
  Standard org.freedesktop.DBus.Introspectable interface definition.
  """
  def introspectable_interface do
    %__MODULE__{
      name: "org.freedesktop.DBus.Introspectable",
      methods: [
        %Method{
          name: "Introspect",
          args: [%Arg{name: "xml_data", type: "s", direction: :out}]
        }
      ]
    }
  end

  @doc """
  Standard org.freedesktop.DBus.Properties interface definition.
  """
  def properties_interface do
    %__MODULE__{
      name: "org.freedesktop.DBus.Properties",
      methods: [
        %Method{
          name: "Get",
          args: [
            %Arg{name: "interface_name", type: "s", direction: :in},
            %Arg{name: "property_name", type: "s", direction: :in},
            %Arg{name: "value", type: "v", direction: :out}
          ]
        },
        %Method{
          name: "Set",
          args: [
            %Arg{name: "interface_name", type: "s", direction: :in},
            %Arg{name: "property_name", type: "s", direction: :in},
            %Arg{name: "value", type: "v", direction: :in}
          ]
        },
        %Method{
          name: "GetAll",
          args: [
            %Arg{name: "interface_name", type: "s", direction: :in},
            %Arg{name: "props", type: "a{sv}", direction: :out}
          ]
        }
      ],
      signals: [
        %Signal{
          name: "PropertiesChanged",
          args: [
            %Arg{name: "interface_name", type: "s"},
            %Arg{name: "changed_properties", type: "a{sv}"},
            %Arg{name: "invalidated_properties", type: "as"}
          ]
        }
      ]
    }
  end

  @doc """
  Standard org.freedesktop.DBus.Peer interface definition.
  """
  def peer_interface do
    %__MODULE__{
      name: "org.freedesktop.DBus.Peer",
      methods: [
        %Method{name: "Ping", args: []},
        %Method{
          name: "GetMachineId",
          args: [%Arg{name: "machine_uuid", type: "s", direction: :out}]
        }
      ]
    }
  end

  @doc """
  The org.freedesktop.DBus interface definition for the bus itself.
  """
  def bus_interface do
    %__MODULE__{
      name: "org.freedesktop.DBus",
      methods: [
        %Method{
          name: "Hello",
          args: [%Arg{name: "unique_name", type: "s", direction: :out}]
        },
        %Method{
          name: "RequestName",
          args: [
            %Arg{name: "name", type: "s", direction: :in},
            %Arg{name: "flags", type: "u", direction: :in},
            %Arg{name: "result", type: "u", direction: :out}
          ]
        },
        %Method{
          name: "ReleaseName",
          args: [
            %Arg{name: "name", type: "s", direction: :in},
            %Arg{name: "result", type: "u", direction: :out}
          ]
        },
        %Method{
          name: "GetNameOwner",
          args: [
            %Arg{name: "name", type: "s", direction: :in},
            %Arg{name: "unique_name", type: "s", direction: :out}
          ]
        },
        %Method{
          name: "ListNames",
          args: [%Arg{name: "names", type: "as", direction: :out}]
        },
        %Method{
          name: "ListActivatableNames",
          args: [%Arg{name: "names", type: "as", direction: :out}]
        },
        %Method{
          name: "NameHasOwner",
          args: [
            %Arg{name: "name", type: "s", direction: :in},
            %Arg{name: "result", type: "b", direction: :out}
          ]
        },
        %Method{
          name: "AddMatch",
          args: [%Arg{name: "rule", type: "s", direction: :in}]
        },
        %Method{
          name: "RemoveMatch",
          args: [%Arg{name: "rule", type: "s", direction: :in}]
        },
        %Method{
          name: "GetId",
          args: [%Arg{name: "id", type: "s", direction: :out}]
        }
      ],
      signals: [
        %Signal{
          name: "NameOwnerChanged",
          args: [
            %Arg{name: "name", type: "s"},
            %Arg{name: "old_owner", type: "s"},
            %Arg{name: "new_owner", type: "s"}
          ]
        },
        %Signal{
          name: "NameAcquired",
          args: [%Arg{name: "name", type: "s"}]
        },
        %Signal{
          name: "NameLost",
          args: [%Arg{name: "name", type: "s"}]
        }
      ]
    }
  end

  # --- XML generation ---

  defp interface_to_xml(%__MODULE__{} = iface) do
    [
      ~s(  <interface name="#{escape_xml(iface.name)}">\n),
      Enum.map(iface.methods, &method_to_xml/1),
      Enum.map(iface.signals, &signal_to_xml/1),
      Enum.map(iface.properties, &property_to_xml/1),
      "  </interface>\n"
    ]
  end

  defp method_to_xml(%Method{args: []} = m) do
    ~s(    <method name="#{escape_xml(m.name)}"/>\n)
  end

  defp method_to_xml(%Method{} = m) do
    [
      ~s(    <method name="#{escape_xml(m.name)}">\n),
      Enum.map(m.args, &arg_to_xml/1),
      "    </method>\n"
    ]
  end

  defp signal_to_xml(%Signal{args: []} = s) do
    ~s(    <signal name="#{escape_xml(s.name)}"/>\n)
  end

  defp signal_to_xml(%Signal{} = s) do
    [
      ~s(    <signal name="#{escape_xml(s.name)}">\n),
      Enum.map(s.args, &arg_to_xml/1),
      "    </signal>\n"
    ]
  end

  defp property_to_xml(%Property{} = p) do
    ~s(    <property name="#{escape_xml(p.name)}" type="#{escape_xml(p.type)}" access="#{p.access}"/>\n)
  end

  defp arg_to_xml(%Arg{} = a) do
    name_attr = if a.name, do: ~s( name="#{escape_xml(a.name)}"), else: ""
    dir_attr = if a.direction, do: ~s( direction="#{a.direction}"), else: ""
    ~s(      <arg#{name_attr} type="#{escape_xml(a.type)}"#{dir_attr}/>\n)
  end

  defp child_node_to_xml(name) do
    ~s(  <node name="#{escape_xml(name)}"/>\n)
  end

  defp escape_xml(nil), do: ""

  defp escape_xml(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(atom) when is_atom(atom), do: escape_xml(Atom.to_string(atom))

  # --- XML parsing (simple regex-based, no XML library dependency) ---

  defp parse_node(xml) do
    path = extract_attr(xml, "node", "name") || "/"

    interfaces =
      Regex.scan(~r/<interface name="([^"]+)">(.*?)<\/interface>/s, xml)
      |> Enum.map(fn [_full, name, body] -> parse_interface(name, body) end)

    children =
      Regex.scan(~r/<node name="([^"]+)"\s*\/>/, xml)
      |> Enum.map(fn [_full, name] -> name end)

    {:ok, path, interfaces, children}
  end

  defp parse_interface(name, body) do
    methods = parse_methods(body)
    signals = parse_signals(body)
    properties = parse_properties(body)

    %__MODULE__{
      name: name,
      methods: methods,
      signals: signals,
      properties: properties
    }
  end

  defp parse_methods(body) do
    # Match methods with args
    with_args =
      Regex.scan(~r/<method name="([^"]+)">\s*(.*?)\s*<\/method>/s, body)
      |> Enum.map(fn [_full, name, args_body] ->
        %Method{name: name, args: parse_args(args_body)}
      end)

    # Match self-closing methods
    without_args =
      Regex.scan(~r/<method name="([^"]+)"\/>/s, body)
      |> Enum.map(fn [_full, name] ->
        %Method{name: name, args: []}
      end)

    with_args ++ without_args
  end

  defp parse_signals(body) do
    with_args =
      Regex.scan(~r/<signal name="([^"]+)">\s*(.*?)\s*<\/signal>/s, body)
      |> Enum.map(fn [_full, name, args_body] ->
        %Signal{name: name, args: parse_args(args_body)}
      end)

    without_args =
      Regex.scan(~r/<signal name="([^"]+)"\/>/s, body)
      |> Enum.map(fn [_full, name] ->
        %Signal{name: name, args: []}
      end)

    with_args ++ without_args
  end

  defp parse_properties(body) do
    Regex.scan(~r/<property name="([^"]+)" type="([^"]+)" access="([^"]+)"\/>/s, body)
    |> Enum.map(fn [_full, name, type, access] ->
      %Property{
        name: name,
        type: type,
        access: String.to_atom(access)
      }
    end)
  end

  defp parse_args(body) do
    Regex.scan(~r/<arg(?:\s+name="([^"]*)")?\s+type="([^"]+)"(?:\s+direction="([^"]+)")?\/>/s, body)
    |> Enum.map(fn match ->
      name = Enum.at(match, 1)
      type = Enum.at(match, 2)
      direction = Enum.at(match, 3)

      %Arg{
        name: if(name == "", do: nil, else: name),
        type: type,
        direction: if(direction, do: String.to_atom(direction), else: nil)
      }
    end)
  end

  defp extract_attr(xml, element, attr) do
    case Regex.run(~r/<#{element}[^>]*\s#{attr}="([^"]+)"/, xml) do
      [_, value] -> value
      nil -> nil
    end
  end
end
