defmodule GaoBus.AuthProtocolTest do
  use ExUnit.Case, async: false

  @rejected "REJECTED EXTERNAL ANONYMOUS\r\n"

  setup do
    Application.stop(:gao_bus)

    socket_path = "/tmp/gao_bus_auth_test_#{System.unique_integer([:positive])}"
    Application.put_env(:gao_bus, :socket_path, socket_path)

    {:ok, sup} = GaoBus.Application.start(:normal, [])
    wait_for_socket(socket_path, System.monotonic_time(:millisecond) + 1_000)

    on_exit(fn ->
      try do
        Supervisor.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      File.rm(socket_path)
    end)

    %{socket_path: socket_path}
  end

  describe "SASL auth discovery" do
    test "bare AUTH returns supported mechanisms", %{socket_path: path} do
      sock = connect(path)

      assert send_auth_line(sock, "AUTH") == @rejected

      :socket.close(sock)
    end

    test "unsupported AUTH mechanism returns supported mechanisms", %{socket_path: path} do
      sock = connect(path)

      assert send_auth_line(sock, "AUTH BOGUS") == @rejected

      :socket.close(sock)
    end

    test "CANCEL returns supported mechanisms", %{socket_path: path} do
      sock = connect(path)

      assert send_auth_line(sock, "CANCEL") == @rejected

      :socket.close(sock)
    end

    test "AUTH EXTERNAL with inline initial response succeeds", %{socket_path: path} do
      sock = connect(path)
      uid_hex = current_uid_hex()

      response = send_auth_line(sock, "AUTH EXTERNAL #{uid_hex}")

      assert String.starts_with?(response, "OK ")
      assert String.ends_with?(response, "\r\n")

      :socket.close(sock)
    end

    test "AUTH EXTERNAL accepts two-step DATA response", %{socket_path: path} do
      sock = connect(path)
      uid_hex = current_uid_hex()

      assert send_auth_line(sock, "AUTH EXTERNAL") == "DATA\r\n"
      assert send_line(sock, "DATA #{uid_hex}") |> String.starts_with?("OK ")

      :socket.close(sock)
    end

    test "unknown auth command returns ERROR", %{socket_path: path} do
      sock = connect(path)

      assert send_auth_line(sock, "FROB") == "ERROR\r\n"

      :socket.close(sock)
    end
  end

  defp connect(path) do
    {:ok, sock} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(sock, %{family: :local, path: path})
    sock
  end

  defp send_auth_line(sock, line) do
    :ok = :socket.sendmsg(sock, %{iov: [<<0>>, line, "\r\n"]})
    recv(sock)
  end

  defp send_line(sock, line) do
    :ok = :socket.sendmsg(sock, %{iov: [line, "\r\n"]})
    recv(sock)
  end

  defp recv(sock) do
    {:ok, msg} = :socket.recvmsg(sock, 0, 0, [], 5_000)
    IO.iodata_to_binary(msg.iov)
  end

  defp current_uid_hex do
    {uid, 0} = System.cmd("id", ["-u"])
    uid |> String.trim() |> Base.encode16(case: :lower)
  end

  defp wait_for_socket(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("socket was not created at #{path}")

      true ->
        receive do
        after
          10 -> wait_for_socket(path, deadline)
        end
    end
  end
end
