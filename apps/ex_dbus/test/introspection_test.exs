defmodule ExDBus.IntrospectionTest do
  use ExUnit.Case

  alias ExDBus.Introspection
  alias ExDBus.Introspection.{Method, Signal, Property, Arg}

  describe "to_xml/3" do
    test "generates minimal node" do
      xml = Introspection.to_xml("/", [])
      assert String.contains?(xml, ~s(<node name="/">))
      assert String.contains?(xml, "</node>")
      assert String.contains?(xml, "<!DOCTYPE node")
    end

    test "generates interface with methods" do
      iface = %Introspection{
        name: "com.example.Foo",
        methods: [
          %Method{
            name: "DoStuff",
            args: [
              %Arg{name: "input", type: "s", direction: :in},
              %Arg{name: "output", type: "s", direction: :out}
            ]
          }
        ]
      }

      xml = Introspection.to_xml("/com/example", [iface])
      assert String.contains?(xml, ~s(<interface name="com.example.Foo">))
      assert String.contains?(xml, ~s(<method name="DoStuff">))
      assert String.contains?(xml, ~s(name="input" type="s" direction="in"))
      assert String.contains?(xml, ~s(name="output" type="s" direction="out"))
      assert String.contains?(xml, "</method>")
      assert String.contains?(xml, "</interface>")
    end

    test "generates self-closing method with no args" do
      iface = %Introspection{
        name: "com.example.Foo",
        methods: [%Method{name: "Ping", args: []}]
      }

      xml = Introspection.to_xml("/", [iface])
      assert String.contains?(xml, ~s(<method name="Ping"/>))
    end

    test "generates signals" do
      iface = %Introspection{
        name: "com.example.Foo",
        signals: [
          %Signal{
            name: "Changed",
            args: [
              %Arg{name: "value", type: "s"}
            ]
          }
        ]
      }

      xml = Introspection.to_xml("/", [iface])
      assert String.contains?(xml, ~s(<signal name="Changed">))
      assert String.contains?(xml, ~s(name="value" type="s"))
    end

    test "generates properties" do
      iface = %Introspection{
        name: "com.example.Foo",
        properties: [
          %Property{name: "Version", type: "s", access: :read},
          %Property{name: "Name", type: "s", access: :readwrite}
        ]
      }

      xml = Introspection.to_xml("/", [iface])
      assert String.contains?(xml, ~s(<property name="Version" type="s" access="read"/>))
      assert String.contains?(xml, ~s(<property name="Name" type="s" access="readwrite"/>))
    end

    test "generates child nodes" do
      xml = Introspection.to_xml("/", [], ["child1", "child2"])
      assert String.contains?(xml, ~s(<node name="child1"/>))
      assert String.contains?(xml, ~s(<node name="child2"/>))
    end

    test "escapes XML special characters" do
      iface = %Introspection{
        name: "com.example.Foo",
        methods: [
          %Method{
            name: "Get",
            args: [%Arg{name: "key", type: "s", direction: :in}]
          }
        ]
      }

      xml = Introspection.to_xml("/test&path", [iface])
      assert String.contains?(xml, "&amp;")
    end

    test "generates multiple interfaces" do
      ifaces = [
        %Introspection{name: "com.example.A", methods: [%Method{name: "M1", args: []}]},
        %Introspection{name: "com.example.B", signals: [%Signal{name: "S1", args: []}]}
      ]

      xml = Introspection.to_xml("/", ifaces)
      assert String.contains?(xml, ~s(<interface name="com.example.A">))
      assert String.contains?(xml, ~s(<interface name="com.example.B">))
    end
  end

  describe "from_xml/1" do
    test "parses minimal node" do
      xml = Introspection.to_xml("/test", [])
      assert {:ok, "/test", [], []} = Introspection.from_xml(xml)
    end

    test "roundtrips interface with methods" do
      iface = %Introspection{
        name: "com.example.Foo",
        methods: [
          %Method{
            name: "DoStuff",
            args: [
              %Arg{name: "input", type: "s", direction: :in},
              %Arg{name: "output", type: "s", direction: :out}
            ]
          }
        ]
      }

      xml = Introspection.to_xml("/com/example", [iface])
      assert {:ok, "/com/example", [parsed], []} = Introspection.from_xml(xml)
      assert parsed.name == "com.example.Foo"
      assert length(parsed.methods) == 1
      [method] = parsed.methods
      assert method.name == "DoStuff"
      assert length(method.args) == 2
    end

    test "roundtrips signals" do
      iface = %Introspection{
        name: "com.example.Foo",
        signals: [
          %Signal{
            name: "Changed",
            args: [%Arg{name: "value", type: "s"}]
          }
        ]
      }

      xml = Introspection.to_xml("/", [iface])
      assert {:ok, "/", [parsed], []} = Introspection.from_xml(xml)
      assert length(parsed.signals) == 1
      [sig] = parsed.signals
      assert sig.name == "Changed"
    end

    test "roundtrips properties" do
      iface = %Introspection{
        name: "com.example.Foo",
        properties: [
          %Property{name: "Version", type: "s", access: :read}
        ]
      }

      xml = Introspection.to_xml("/", [iface])
      assert {:ok, "/", [parsed], []} = Introspection.from_xml(xml)
      assert length(parsed.properties) == 1
      [prop] = parsed.properties
      assert prop.name == "Version"
      assert prop.type == "s"
      assert prop.access == :read
    end

    test "parses child nodes" do
      xml = Introspection.to_xml("/", [], ["child1", "child2"])
      assert {:ok, "/", [], children} = Introspection.from_xml(xml)
      assert "child1" in children
      assert "child2" in children
    end
  end

  describe "standard interfaces" do
    test "bus_interface has standard methods" do
      iface = Introspection.bus_interface()
      assert iface.name == "org.freedesktop.DBus"
      method_names = Enum.map(iface.methods, & &1.name)
      assert "Hello" in method_names
      assert "RequestName" in method_names
      assert "ReleaseName" in method_names
      assert "ListNames" in method_names
      assert "AddMatch" in method_names
      assert "RemoveMatch" in method_names
      assert "GetId" in method_names
    end

    test "bus_interface has standard signals" do
      iface = Introspection.bus_interface()
      signal_names = Enum.map(iface.signals, & &1.name)
      assert "NameOwnerChanged" in signal_names
      assert "NameAcquired" in signal_names
      assert "NameLost" in signal_names
    end

    test "introspectable_interface" do
      iface = Introspection.introspectable_interface()
      assert iface.name == "org.freedesktop.DBus.Introspectable"
      assert length(iface.methods) == 1
      assert hd(iface.methods).name == "Introspect"
    end

    test "properties_interface" do
      iface = Introspection.properties_interface()
      assert iface.name == "org.freedesktop.DBus.Properties"
      method_names = Enum.map(iface.methods, & &1.name)
      assert "Get" in method_names
      assert "Set" in method_names
      assert "GetAll" in method_names
    end

    test "peer_interface" do
      iface = Introspection.peer_interface()
      assert iface.name == "org.freedesktop.DBus.Peer"
      method_names = Enum.map(iface.methods, & &1.name)
      assert "Ping" in method_names
      assert "GetMachineId" in method_names
    end

    test "bus interface XML roundtrips" do
      xml = Introspection.to_xml("/org/freedesktop/DBus", [
        Introspection.bus_interface(),
        Introspection.introspectable_interface(),
        Introspection.properties_interface(),
        Introspection.peer_interface()
      ])

      assert {:ok, "/org/freedesktop/DBus", interfaces, []} = Introspection.from_xml(xml)
      assert length(interfaces) == 4
      names = Enum.map(interfaces, & &1.name)
      assert "org.freedesktop.DBus" in names
      assert "org.freedesktop.DBus.Introspectable" in names
      assert "org.freedesktop.DBus.Properties" in names
      assert "org.freedesktop.DBus.Peer" in names
    end
  end
end
