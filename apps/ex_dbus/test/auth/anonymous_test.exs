defmodule ExDBus.Auth.AnonymousTest do
  use ExUnit.Case, async: true

  alias ExDBus.Auth.Anonymous

  describe "init/1" do
    test "initializes with :init state" do
      state = Anonymous.init()
      assert state.state == :init
    end
  end

  describe "initial_command/1" do
    test "sends AUTH ANONYMOUS" do
      state = Anonymous.init()
      {:send, command, new_state} = Anonymous.initial_command(state)
      assert command == "AUTH ANONYMOUS"
      assert new_state.state == :waiting_ok
    end
  end

  describe "handle_line/2" do
    test "OK response transitions to authenticated" do
      state = %Anonymous{state: :waiting_ok}
      {:ok, guid, new_state} = Anonymous.handle_line("OK server_guid_123", state)

      assert guid == "server_guid_123"
      assert new_state.state == :authenticated
      assert new_state.guid == "server_guid_123"
    end

    test "REJECTED response returns error" do
      state = %Anonymous{state: :waiting_ok}
      assert {:error, :rejected} = Anonymous.handle_line("REJECTED", state)
    end

    test "unexpected response returns error" do
      state = %Anonymous{state: :waiting_ok}
      assert {:error, {:unexpected_response, "GARBAGE"}} = Anonymous.handle_line("GARBAGE", state)
    end

    test "wrong state returns error" do
      state = %Anonymous{state: :authenticated, guid: "x"}
      assert {:error, {:unexpected_state, :authenticated, _}} = Anonymous.handle_line("OK guid", state)
    end
  end
end
