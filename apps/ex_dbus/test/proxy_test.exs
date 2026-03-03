defmodule ExDBus.ProxyTest do
  use ExUnit.Case

  alias ExDBus.{Message, Proxy}

  describe "new/3" do
    test "creates proxy with defaults" do
      proxy = Proxy.new(:fake_conn, "org.freedesktop.DBus", "/org/freedesktop/DBus")
      assert proxy.connection == :fake_conn
      assert proxy.destination == "org.freedesktop.DBus"
      assert proxy.path == "/org/freedesktop/DBus"
    end

    test "defaults path to /" do
      proxy = Proxy.new(:fake_conn, "com.example.Service")
      assert proxy.path == "/"
    end
  end

  describe "call/4" do
    test "sends method_call with correct fields" do
      conn = start_mock_connection()
      proxy = Proxy.new(conn, "com.test.Svc", "/com/test/Obj")

      {:ok, _reply} = Proxy.call(proxy, "com.test.Iface", "DoStuff")

      assert_receive {:mock_call, msg}
      assert msg.type == :method_call
      assert msg.destination == "com.test.Svc"
      assert msg.path == "/com/test/Obj"
      assert msg.interface == "com.test.Iface"
      assert msg.member == "DoStuff"
    end

    test "passes signature and body" do
      conn = start_mock_connection()
      proxy = Proxy.new(conn, "com.test.Svc", "/com/test/Obj")

      {:ok, _reply} =
        Proxy.call(proxy, "com.test.Iface", "Echo",
          signature: "s",
          body: ["hello"]
        )

      assert_receive {:mock_call, msg}
      assert msg.signature == "s"
      assert msg.body == ["hello"]
    end
  end

  describe "get_property/4" do
    test "calls Properties.Get and unwraps variant" do
      conn =
        start_mock_connection(fn msg ->
          # Return a variant value
          Message.method_return(msg.serial,
            signature: "v",
            body: [{"s", "dark"}]
          )
        end)

      proxy = Proxy.new(conn, "com.test.Svc", "/com/test/Obj")

      {:ok, {"s", "dark"}} = Proxy.get_property(proxy, "com.test.Iface", "Theme")
    end

    test "sends correct interface and property names" do
      conn =
        start_mock_connection(fn msg ->
          Message.method_return(msg.serial,
            signature: "v",
            body: [{"s", "value"}]
          )
        end)

      proxy = Proxy.new(conn, "com.test.Svc", "/com/test/Obj")

      Proxy.get_property(proxy, "com.test.Iface", "Theme")

      # Verify the captured message
      assert_receive {:mock_call, msg}
      assert msg.interface == "org.freedesktop.DBus.Properties"
      assert msg.member == "Get"
      assert msg.body == ["com.test.Iface", "Theme"]
    end
  end

  describe "set_property/5" do
    test "calls Properties.Set with variant" do
      conn = start_mock_connection()
      proxy = Proxy.new(conn, "com.test.Svc", "/com/test/Obj")

      Proxy.set_property(proxy, "com.test.Iface", "Theme", {"s", "light"})

      assert_receive {:mock_call, msg}
      assert msg.interface == "org.freedesktop.DBus.Properties"
      assert msg.member == "Set"
      assert msg.body == ["com.test.Iface", "Theme", {"s", "light"}]
    end
  end

  describe "get_all_properties/3" do
    test "calls Properties.GetAll and unwraps" do
      conn =
        start_mock_connection(fn msg ->
          Message.method_return(msg.serial,
            signature: "a{sv}",
            body: [[{"Theme", {"s", "dark"}}, {"FontSize", {"u", 14}}]]
          )
        end)

      proxy = Proxy.new(conn, "com.test.Svc", "/com/test/Obj")

      {:ok, props} = Proxy.get_all_properties(proxy, "com.test.Iface")
      assert [{"Theme", {"s", "dark"}}, {"FontSize", {"u", 14}}] = props
    end
  end

  describe "introspect/2" do
    test "calls Introspectable.Introspect and unwraps XML" do
      xml = "<node><interface name=\"com.test\"/></node>"

      conn =
        start_mock_connection(fn msg ->
          Message.method_return(msg.serial,
            signature: "s",
            body: [xml]
          )
        end)

      proxy = Proxy.new(conn, "com.test.Svc", "/com/test/Obj")

      {:ok, ^xml} = Proxy.introspect(proxy)
    end
  end

  describe "emit_signal/4" do
    test "sends signal through connection" do
      conn = start_mock_signal_connection()
      proxy = Proxy.new(conn, "com.test.Svc", "/com/test/Obj")

      :ok =
        Proxy.emit_signal(proxy, "com.test.Iface", "Updated",
          signature: "s",
          body: ["new_value"]
        )

      assert_receive {:mock_signal, signal}
      assert signal.type == :signal
      assert signal.path == "/com/test/Obj"
      assert signal.interface == "com.test.Iface"
      assert signal.member == "Updated"
      assert signal.body == ["new_value"]
    end
  end

  # --- Mock Connection GenServer ---

  defp start_mock_connection(reply_fn \\ nil) do
    test_pid = self()

    reply_fn =
      reply_fn ||
        fn msg ->
          Message.method_return(msg.serial, body: [])
        end

    {:ok, pid} =
      GenServer.start_link(MockConnection, %{reply_fn: reply_fn, test_pid: test_pid})

    pid
  end

  defp start_mock_signal_connection do
    test_pid = self()
    {:ok, pid} = GenServer.start_link(MockSignalConnection, %{test_pid: test_pid})
    pid
  end
end

defmodule MockConnection do
  use GenServer

  def init(state), do: {:ok, state}

  def handle_call({:call, msg}, _from, state) do
    send(state.test_pid, {:mock_call, msg})
    reply = state.reply_fn.(msg)
    {:reply, {:ok, reply}, state}
  end
end

defmodule MockSignalConnection do
  use GenServer

  def init(state), do: {:ok, state}

  def handle_cast({:send, msg}, state) do
    send(state.test_pid, {:mock_signal, msg})
    {:noreply, state}
  end
end
