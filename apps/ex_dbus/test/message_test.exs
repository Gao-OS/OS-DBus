defmodule ExDBus.MessageTest do
  use ExUnit.Case
  alias ExDBus.Message

  describe "message construction" do
    test "creates method_call message" do
      msg = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        serial: 1, destination: "org.freedesktop.DBus")

      assert msg.type == :method_call
      assert msg.serial == 1
      assert msg.path == "/org/freedesktop/DBus"
      assert msg.interface == "org.freedesktop.DBus"
      assert msg.member == "Hello"
      assert msg.destination == "org.freedesktop.DBus"
    end

    test "creates method_return message" do
      msg = Message.method_return(1, serial: 2, destination: ":1.1",
        signature: "s", body: ["hello"])

      assert msg.type == :method_return
      assert msg.reply_serial == 1
      assert msg.serial == 2
      assert msg.body == ["hello"]
    end

    test "creates error message" do
      msg = Message.error("org.freedesktop.DBus.Error.UnknownMethod", 1,
        serial: 2, signature: "s", body: ["Method not found"])

      assert msg.type == :error
      assert msg.error_name == "org.freedesktop.DBus.Error.UnknownMethod"
      assert msg.reply_serial == 1
    end

    test "creates signal message" do
      msg = Message.signal("/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged",
        serial: 3, signature: "sss", body: [":1.1", "", ":1.1"])

      assert msg.type == :signal
      assert msg.path == "/org/freedesktop/DBus"
      assert msg.member == "NameOwnerChanged"
      assert msg.body == [":1.1", "", ":1.1"]
    end
  end

  describe "message encode/decode roundtrip" do
    test "roundtrips method_call without body" do
      msg = Message.method_call("/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello",
        serial: 1, destination: "org.freedesktop.DBus")

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)

      assert decoded.type == :method_call
      assert decoded.serial == 1
      assert decoded.path == "/org/freedesktop/DBus"
      assert decoded.interface == "org.freedesktop.DBus"
      assert decoded.member == "Hello"
      assert decoded.destination == "org.freedesktop.DBus"
      assert decoded.body == []
    end

    test "roundtrips method_call with string body" do
      msg = Message.method_call("/org/test", "org.test.Iface", "GetValue",
        serial: 42, destination: "org.test.Service",
        signature: "s", body: ["test_key"])

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)

      assert decoded.type == :method_call
      assert decoded.serial == 42
      assert decoded.path == "/org/test"
      assert decoded.member == "GetValue"
      assert decoded.signature == "s"
      assert decoded.body == ["test_key"]
    end

    test "roundtrips method_call with multiple body args" do
      msg = Message.method_call("/org/test", "org.test.Iface", "SetValue",
        serial: 5, signature: "si", body: ["key", 42])

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)

      assert decoded.body == ["key", 42]
      assert decoded.signature == "si"
    end

    test "roundtrips method_return with body" do
      msg = Message.method_return(1,
        serial: 2, destination: ":1.1",
        signature: "i", body: [42])

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)

      assert decoded.type == :method_return
      assert decoded.reply_serial == 1
      assert decoded.body == [42]
    end

    test "roundtrips error message" do
      msg = Message.error("org.freedesktop.DBus.Error.Failed", 5,
        serial: 6, signature: "s", body: ["Something went wrong"])

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)

      assert decoded.type == :error
      assert decoded.error_name == "org.freedesktop.DBus.Error.Failed"
      assert decoded.reply_serial == 5
      assert decoded.body == ["Something went wrong"]
    end

    test "roundtrips signal" do
      msg = Message.signal("/org/freedesktop/DBus", "org.freedesktop.DBus", "NameAcquired",
        serial: 1, signature: "s", body: [":1.42"])

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)

      assert decoded.type == :signal
      assert decoded.path == "/org/freedesktop/DBus"
      assert decoded.interface == "org.freedesktop.DBus"
      assert decoded.member == "NameAcquired"
      assert decoded.body == [":1.42"]
    end

    test "roundtrips with big endian" do
      msg = Message.method_call("/org/test", "org.test.Iface", "Ping",
        serial: 1, signature: "i", body: [99])

      binary = Message.encode_message(msg, :big)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)

      assert decoded.type == :method_call
      assert decoded.serial == 1
      assert decoded.body == [99]
    end

    test "roundtrips message with no_reply_expected flag" do
      msg = Message.method_call("/org/test", "org.test.Iface", "Fire",
        serial: 1, flags: 0x01)

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)

      assert decoded.flags == 0x01
    end
  end

  describe "real-world D-Bus messages" do
    test "Hello method call (first message on bus)" do
      msg = Message.method_call(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "Hello",
        serial: 1, destination: "org.freedesktop.DBus"
      )

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)
      assert decoded.member == "Hello"
      assert decoded.destination == "org.freedesktop.DBus"
    end

    test "RequestName method call" do
      msg = Message.method_call(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "RequestName",
        serial: 2,
        destination: "org.freedesktop.DBus",
        signature: "su",
        body: ["org.example.MyService", 0]
      )

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)
      assert decoded.member == "RequestName"
      assert decoded.body == ["org.example.MyService", 0]
    end

    test "NameOwnerChanged signal" do
      msg = Message.signal(
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "NameOwnerChanged",
        serial: 10,
        signature: "sss",
        body: ["org.example.MyService", "", ":1.42"]
      )

      binary = Message.encode_message(msg)
      assert {:ok, decoded, <<>>} = Message.decode_message(binary)
      assert decoded.member == "NameOwnerChanged"
      assert decoded.body == ["org.example.MyService", "", ":1.42"]
    end
  end

  describe "error handling" do
    test "rejects too-short binary" do
      assert {:error, :insufficient_data} = Message.decode_message(<<1, 2, 3>>)
    end

    test "rejects invalid endianness byte" do
      binary = <<0xFF, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
      assert {:error, {:invalid_endianness, 0xFF}} = Message.decode_message(binary)
    end
  end

  describe "multiple messages in stream" do
    test "decodes first message and returns rest" do
      msg1 = Message.method_call("/org/test", "org.test.Iface", "Ping", serial: 1)
      msg2 = Message.method_call("/org/test", "org.test.Iface", "Pong", serial: 2)

      bin1 = Message.encode_message(msg1)
      bin2 = Message.encode_message(msg2)
      stream = bin1 <> bin2

      assert {:ok, decoded1, rest} = Message.decode_message(stream)
      assert decoded1.member == "Ping"

      assert {:ok, decoded2, <<>>} = Message.decode_message(rest)
      assert decoded2.member == "Pong"
    end
  end
end
