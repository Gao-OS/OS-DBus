defmodule GaoBus.PolicyTest do
  use ExUnit.Case

  alias GaoBus.Policy.Capability

  setup do
    # Ensure the app is running (integration tests may have stopped it)
    Application.stop(:gao_bus)
    Process.sleep(50)

    socket_path = "/tmp/gao_bus_policy_test_#{System.unique_integer([:positive])}"
    Application.put_env(:gao_bus, :socket_path, socket_path)
    {:ok, sup} = GaoBus.Application.start(:normal, [])
    Process.sleep(50)

    on_exit(fn ->
      try do
        Supervisor.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
      File.rm(socket_path)
    end)

    :ok
  end

  describe "capability management" do
    test "grant and list capabilities" do
      Capability.grant(":1.test1", {:send, "com.example.Foo"})
      caps = Capability.capabilities(":1.test1")
      assert {:send, "com.example.Foo"} in caps

      # Cleanup
      Capability.revoke(":1.test1", {:send, "com.example.Foo"})
    end

    test "revoke removes capability" do
      Capability.grant(":1.test2", {:send, "com.example.Bar"})
      Capability.revoke(":1.test2", {:send, "com.example.Bar"})
      caps = Capability.capabilities(":1.test2")
      refute {:send, "com.example.Bar"} in caps
    end

    test "peer_disconnected removes all capabilities" do
      Capability.grant(":1.test3", {:send, "a"})
      Capability.grant(":1.test3", {:own, "b"})
      Capability.peer_disconnected(":1.test3")
      # Give cast time to process
      Process.sleep(10)
      assert Capability.capabilities(":1.test3") == []
    end
  end

  describe "setup_defaults" do
    test "root gets superuser capability" do
      Capability.setup_defaults(":1.root_test", %{uid: 0})
      Process.sleep(10)
      caps = Capability.capabilities(":1.root_test")
      assert {:all, :all} in caps

      Capability.peer_disconnected(":1.root_test")
    end

    test "regular user gets send capability" do
      Capability.setup_defaults(":1.user_test", %{uid: 1000})
      Process.sleep(10)
      caps = Capability.capabilities(":1.user_test")
      assert {:send, :any} in caps
      assert {:send, "org.freedesktop.DBus"} in caps

      Capability.peer_disconnected(":1.user_test")
    end

    test "system user gets own capability" do
      Capability.setup_defaults(":1.sys_test", %{uid: 100})
      Process.sleep(10)
      caps = Capability.capabilities(":1.sys_test")
      assert {:own, :any} in caps
      assert {:send, :any} in caps

      Capability.peer_disconnected(":1.sys_test")
    end
  end

  describe "check_send" do
    test "superuser can send anything" do
      Capability.grant(":1.su", {:all, :all})
      creds = %{unique_name: ":1.su"}
      info = %{type: :method_call, destination: "com.secret.Service",
               interface: "com.secret.Iface", member: "DoStuff",
               sender: ":1.su", path: "/"}
      assert :allow = Capability.check_send(creds, info)

      Capability.peer_disconnected(":1.su")
    end

    test "messages to bus are always allowed" do
      creds = %{unique_name: ":1.nobody"}
      info = %{type: :method_call, destination: "org.freedesktop.DBus",
               interface: "org.freedesktop.DBus", member: "Hello",
               sender: ":1.nobody", path: "/"}
      assert :allow = Capability.check_send(creds, info)
    end

    test "method returns are always allowed" do
      creds = %{unique_name: ":1.nobody"}
      info = %{type: :method_return, destination: ":1.2",
               interface: nil, member: nil,
               sender: ":1.nobody", path: nil}
      assert :allow = Capability.check_send(creds, info)
    end

    test "send with :any capability allows all" do
      Capability.grant(":1.any_send", {:send, :any})
      creds = %{unique_name: ":1.any_send"}
      info = %{type: :method_call, destination: "com.example.Foo",
               interface: "com.example.Foo", member: "Bar",
               sender: ":1.any_send", path: "/"}
      assert :allow = Capability.check_send(creds, info)

      Capability.peer_disconnected(":1.any_send")
    end

    test "specific call capability works" do
      Capability.grant(":1.specific", {:call, {"com.example.Svc", "com.example.Iface", "AllowedMethod"}})
      creds = %{unique_name: ":1.specific"}

      allowed = %{type: :method_call, destination: "com.example.Svc",
                   interface: "com.example.Iface", member: "AllowedMethod",
                   sender: ":1.specific", path: "/"}
      assert :allow = Capability.check_send(creds, allowed)

      denied = %{type: :method_call, destination: "com.example.Svc",
                  interface: "com.example.Iface", member: "DeniedMethod",
                  sender: ":1.specific", path: "/"}
      assert {:deny, _} = Capability.check_send(creds, denied)

      Capability.peer_disconnected(":1.specific")
    end
  end

  describe "check_own" do
    test "superuser can own anything" do
      Capability.grant(":1.su2", {:all, :all})
      creds = %{unique_name: ":1.su2"}
      assert :allow = Capability.check_own(creds, "com.any.Name")

      Capability.peer_disconnected(":1.su2")
    end

    test "specific own capability works" do
      Capability.grant(":1.owner", {:own, "com.example.MyService"})
      creds = %{unique_name: ":1.owner"}

      assert :allow = Capability.check_own(creds, "com.example.MyService")
      assert {:deny, _} = Capability.check_own(creds, "com.example.OtherService")

      Capability.peer_disconnected(":1.owner")
    end

    test ":any own capability works" do
      Capability.grant(":1.any_own", {:own, :any})
      creds = %{unique_name: ":1.any_own"}
      assert :allow = Capability.check_own(creds, "any.name.works")

      Capability.peer_disconnected(":1.any_own")
    end
  end
end
