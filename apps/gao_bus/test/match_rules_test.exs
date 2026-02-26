defmodule GaoBus.MatchRulesTest do
  use ExUnit.Case

  alias GaoBus.MatchRules
  alias ExDBus.Message

  describe "parse/1" do
    test "parses type filter" do
      assert {:ok, rule} = MatchRules.parse("type='signal'")
      assert rule.type == :signal
    end

    test "parses sender filter" do
      assert {:ok, rule} = MatchRules.parse("sender='org.freedesktop.DBus'")
      assert rule.sender == "org.freedesktop.DBus"
    end

    test "parses multiple filters" do
      assert {:ok, rule} = MatchRules.parse(
        "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'"
      )
      assert rule.type == :signal
      assert rule.sender == "org.freedesktop.DBus"
      assert rule.interface == "org.freedesktop.DBus"
      assert rule.member == "NameOwnerChanged"
    end

    test "parses path filter" do
      assert {:ok, rule} = MatchRules.parse("path='/org/freedesktop/DBus'")
      assert rule.path == "/org/freedesktop/DBus"
    end

    test "parses path_namespace filter" do
      assert {:ok, rule} = MatchRules.parse("path_namespace='/org/freedesktop'")
      assert rule.path_namespace == "/org/freedesktop"
    end

    test "parses arg filters" do
      assert {:ok, rule} = MatchRules.parse("arg0='hello',arg2path='/com'")
      assert rule.args == %{{:arg, 0} => "hello", {:arg_path, 2} => "/com"}
    end

    test "parses eavesdrop" do
      assert {:ok, rule} = MatchRules.parse("eavesdrop='true'")
      assert rule.eavesdrop == true
    end

    test "parses empty string" do
      assert {:ok, rule} = MatchRules.parse("")
      assert rule.type == nil
    end

    test "rejects invalid type" do
      assert {:error, {:invalid_type, "bogus"}} = MatchRules.parse("type='bogus'")
    end

    test "rejects unknown key" do
      assert {:error, {:unknown_key, "foo"}} = MatchRules.parse("foo='bar'")
    end
  end

  describe "matches?/2" do
    test "empty rule matches everything" do
      {:ok, rule} = MatchRules.parse("")
      signal = Message.signal("/test", "com.example.Test", "Foo")
      assert MatchRules.matches?(rule, signal)
    end

    test "type filter matches" do
      {:ok, rule} = MatchRules.parse("type='signal'")
      signal = Message.signal("/test", "com.example.Test", "Foo")
      assert MatchRules.matches?(rule, signal)
    end

    test "type filter rejects non-matching" do
      {:ok, rule} = MatchRules.parse("type='method_call'")
      signal = Message.signal("/test", "com.example.Test", "Foo")
      refute MatchRules.matches?(rule, signal)
    end

    test "sender filter matches" do
      {:ok, rule} = MatchRules.parse("sender=':1.1'")
      signal = Message.signal("/test", "com.example.Test", "Foo")
      signal = %{signal | sender: ":1.1"}
      assert MatchRules.matches?(rule, signal)
    end

    test "sender filter rejects non-matching" do
      {:ok, rule} = MatchRules.parse("sender=':1.1'")
      signal = Message.signal("/test", "com.example.Test", "Foo")
      signal = %{signal | sender: ":1.2"}
      refute MatchRules.matches?(rule, signal)
    end

    test "interface filter matches" do
      {:ok, rule} = MatchRules.parse("interface='com.example.Test'")
      signal = Message.signal("/test", "com.example.Test", "Foo")
      assert MatchRules.matches?(rule, signal)
    end

    test "member filter matches" do
      {:ok, rule} = MatchRules.parse("member='Foo'")
      signal = Message.signal("/test", "com.example.Test", "Foo")
      assert MatchRules.matches?(rule, signal)
    end

    test "path filter matches exact path" do
      {:ok, rule} = MatchRules.parse("path='/org/freedesktop/DBus'")
      signal = Message.signal("/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged")
      assert MatchRules.matches?(rule, signal)
    end

    test "path filter rejects non-matching path" do
      {:ok, rule} = MatchRules.parse("path='/org/freedesktop/DBus'")
      signal = Message.signal("/other/path", "org.freedesktop.DBus", "NameOwnerChanged")
      refute MatchRules.matches?(rule, signal)
    end

    test "path_namespace matches prefix" do
      {:ok, rule} = MatchRules.parse("path_namespace='/org/freedesktop'")

      signal1 = Message.signal("/org/freedesktop/DBus", "org.freedesktop.DBus", "Sig")
      assert MatchRules.matches?(rule, signal1)

      signal2 = Message.signal("/org/freedesktop", "org.freedesktop.DBus", "Sig")
      assert MatchRules.matches?(rule, signal2)

      signal3 = Message.signal("/org/other", "org.freedesktop.DBus", "Sig")
      refute MatchRules.matches?(rule, signal3)
    end

    test "arg0 filter matches" do
      {:ok, rule} = MatchRules.parse("arg0='hello'")
      signal = Message.signal("/test", "com.example.Test", "Foo",
        signature: "s", body: ["hello"])
      assert MatchRules.matches?(rule, signal)
    end

    test "arg0 filter rejects non-matching" do
      {:ok, rule} = MatchRules.parse("arg0='hello'")
      signal = Message.signal("/test", "com.example.Test", "Foo",
        signature: "s", body: ["goodbye"])
      refute MatchRules.matches?(rule, signal)
    end

    test "compound rule matches" do
      {:ok, rule} = MatchRules.parse(
        "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'"
      )

      signal = %Message{
        type: :signal,
        serial: 1,
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        member: "NameOwnerChanged",
        sender: "org.freedesktop.DBus",
        signature: "sss",
        body: ["com.example.Test", "", ":1.1"]
      }

      assert MatchRules.matches?(rule, signal)
    end

    test "compound rule rejects partial match" do
      {:ok, rule} = MatchRules.parse(
        "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'"
      )

      signal = %Message{
        type: :signal,
        serial: 1,
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        member: "SomethingElse",
        sender: "org.freedesktop.DBus"
      }

      refute MatchRules.matches?(rule, signal)
    end
  end
end
