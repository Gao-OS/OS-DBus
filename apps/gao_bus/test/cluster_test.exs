defmodule GaoBus.ClusterTest do
  use ExUnit.Case

  alias GaoBus.Cluster

  setup do
    # Ensure gao_bus is running
    Application.stop(:gao_bus)
    Process.sleep(50)

    socket_path = "/tmp/gao_bus_cluster_test_#{System.unique_integer([:positive])}"
    Application.put_env(:gao_bus, :socket_path, socket_path)
    Application.put_env(:gao_bus, :cluster, false)
    {:ok, sup} = GaoBus.Application.start(:normal, [])
    Process.sleep(50)

    on_exit(fn ->
      Application.put_env(:gao_bus, :cluster, false)

      try do
        Supervisor.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      File.rm(socket_path)
    end)

    :ok
  end

  describe "Cluster GenServer" do
    test "starts and joins pg group" do
      {:ok, pid} = Cluster.start_link()

      assert Process.alive?(pid)
      assert Cluster.cluster_names() == []

      GenServer.stop(pid)
    end

    test "register_name adds to local names" do
      {:ok, pid} = Cluster.start_link()

      Cluster.register_name("org.test.Service", self())
      Process.sleep(10)

      names = Cluster.cluster_names()
      assert {"org.test.Service", this_node} = List.keyfind(names, "org.test.Service", 0)
      assert this_node == node()

      GenServer.stop(pid)
    end

    test "unregister_name removes from local names" do
      {:ok, pid} = Cluster.start_link()

      Cluster.register_name("org.test.Remove", self())
      Process.sleep(10)

      Cluster.unregister_name("org.test.Remove")
      Process.sleep(10)

      names = Cluster.cluster_names()
      assert names == []

      GenServer.stop(pid)
    end

    test "nodes returns empty list in single-node mode" do
      {:ok, pid} = Cluster.start_link()
      assert Cluster.nodes() == []
      GenServer.stop(pid)
    end

    test "route_remote returns not_found for unknown name" do
      {:ok, pid} = Cluster.start_link()

      msg = %ExDBus.Message{
        type: :method_call,
        serial: 1,
        destination: "org.nonexistent.Service",
        interface: "org.nonexistent.Iface",
        member: "DoStuff"
      }

      assert {:error, :not_found} = Cluster.route_remote(msg)

      GenServer.stop(pid)
    end
  end
end
