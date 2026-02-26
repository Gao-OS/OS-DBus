defmodule ExDBus.Auth.ExternalTest do
  use ExUnit.Case, async: true

  alias ExDBus.Auth.External

  describe "init/1" do
    test "uses provided uid" do
      state = External.init(uid: 1000)
      assert state.uid == 1000
      assert state.state == :init
    end

    test "defaults to current uid" do
      state = External.init()
      assert is_integer(state.uid)
      assert state.state == :init
    end
  end

  describe "initial_command/1" do
    test "sends AUTH EXTERNAL with hex-encoded uid" do
      state = External.init(uid: 1000)
      {:send, command, new_state} = External.initial_command(state)

      # "1000" as hex: "1" = 0x31, "0" = 0x30, "0" = 0x30, "0" = 0x30
      assert command == "AUTH EXTERNAL 31303030"
      assert new_state.state == :waiting_ok
    end

    test "hex encodes uid 0" do
      state = External.init(uid: 0)
      {:send, command, _} = External.initial_command(state)
      # "0" = 0x30
      assert command == "AUTH EXTERNAL 30"
    end
  end

  describe "handle_line/2" do
    test "OK response transitions to authenticated" do
      state = %External{uid: 1000, state: :waiting_ok}
      {:ok, guid, new_state} = External.handle_line("OK abc123def", state)

      assert guid == "abc123def"
      assert new_state.state == :authenticated
      assert new_state.guid == "abc123def"
    end

    test "OK response trims whitespace from guid" do
      state = %External{uid: 1000, state: :waiting_ok}
      {:ok, guid, _} = External.handle_line("OK abc123  ", state)
      assert guid == "abc123"
    end

    test "REJECTED response returns error" do
      state = %External{uid: 1000, state: :waiting_ok}
      assert {:error, :rejected} = External.handle_line("REJECTED", state)
    end

    test "REJECTED with mechanisms returns error" do
      state = %External{uid: 1000, state: :waiting_ok}
      assert {:error, :rejected} = External.handle_line("REJECTED EXTERNAL DBUS_COOKIE_SHA1", state)
    end

    test "ERROR response returns auth_error" do
      state = %External{uid: 1000, state: :waiting_ok}
      assert {:error, {:auth_error, _}} = External.handle_line("ERROR some error", state)
    end

    test "unexpected response returns error" do
      state = %External{uid: 1000, state: :waiting_ok}
      assert {:error, {:unexpected_response, "GARBAGE"}} = External.handle_line("GARBAGE", state)
    end

    test "wrong state returns error" do
      state = %External{uid: 1000, state: :init}
      assert {:error, {:unexpected_state, :init, _}} = External.handle_line("OK guid", state)
    end
  end
end
