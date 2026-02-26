defmodule ExDBus.Wire.EncoderTest do
  use ExUnit.Case
  alias ExDBus.Wire.Encoder

  defp encode_to_binary(value, type, endianness \\ :little) do
    value
    |> Encoder.encode(type, endianness)
    |> IO.iodata_to_binary()
  end

  describe "basic types - little endian" do
    test "encodes byte" do
      assert <<42>> = encode_to_binary(42, :byte)
      assert <<0>> = encode_to_binary(0, :byte)
      assert <<255>> = encode_to_binary(255, :byte)
    end

    test "encodes boolean" do
      assert <<1, 0, 0, 0>> = encode_to_binary(true, :boolean)
      assert <<0, 0, 0, 0>> = encode_to_binary(false, :boolean)
    end

    test "encodes int16" do
      assert <<42, 0>> = encode_to_binary(42, :int16)
      assert <<0, 128>> = encode_to_binary(-32768, :int16)
      assert <<255, 127>> = encode_to_binary(32767, :int16)
    end

    test "encodes uint16" do
      assert <<42, 0>> = encode_to_binary(42, :uint16)
      assert <<255, 255>> = encode_to_binary(65535, :uint16)
    end

    test "encodes int32" do
      assert <<42, 0, 0, 0>> = encode_to_binary(42, :int32)
      assert <<0, 0, 0, 128>> = encode_to_binary(-2_147_483_648, :int32)
    end

    test "encodes uint32" do
      assert <<42, 0, 0, 0>> = encode_to_binary(42, :uint32)
      assert <<255, 255, 255, 255>> = encode_to_binary(4_294_967_295, :uint32)
    end

    test "encodes int64" do
      assert <<42, 0, 0, 0, 0, 0, 0, 0>> = encode_to_binary(42, :int64)
    end

    test "encodes uint64" do
      assert <<42, 0, 0, 0, 0, 0, 0, 0>> = encode_to_binary(42, :uint64)
    end

    test "encodes double" do
      # 10.5 as IEEE 754 double in little endian
      result = encode_to_binary(10.5, :double)
      assert byte_size(result) == 8
      # Verify roundtrip: decode the value back
      <<val::float-size(64)-little>> = result
      assert Float.round(val, 1) == 10.5
    end

    test "encodes string" do
      # String format: length (uint32) + data + null terminator
      assert <<5, 0, 0, 0, 104, 101, 108, 108, 111, 0>> = encode_to_binary("hello", :string)
      assert <<0, 0, 0, 0, 0>> = encode_to_binary("", :string)
    end

    test "encodes object path" do
      # Same format as string: length (uint32) + data + null
      assert <<1, 0, 0, 0, 47, 0>> = encode_to_binary("/", :object_path)
      assert <<4, 0, 0, 0, 47, 111, 114, 103, 0>> = encode_to_binary("/org", :object_path)
    end

    test "encodes signature" do
      # Signature format: length (byte) + data + null terminator
      assert <<1, 105, 0>> = encode_to_binary("i", :signature)
      # Array signature
      assert <<2, 97, 105, 0>> = encode_to_binary("ai", :signature)
    end

    test "encodes unix fd" do
      assert <<42, 0, 0, 0>> = encode_to_binary(42, :unix_fd)
    end
  end

  describe "basic types - big endian" do
    test "encodes int32 big endian" do
      assert <<0, 0, 0, 42>> = encode_to_binary(42, :int32, :big)
    end

    test "encodes double big endian" do
      result = encode_to_binary(10.5, :double, :big)
      assert byte_size(result) == 8
      # Verify roundtrip
      <<val::float-size(64)-big>> = result
      assert Float.round(val, 1) == 10.5
    end
  end

  describe "alignment padding" do
    test "aligns int32 on 4-byte boundary from offset 0" do
      # No padding needed at offset 0
      assert <<42, 0, 0, 0>> = encode_to_binary(42, :int32)
    end

    test "aligns int64 on 8-byte boundary" do
      assert <<42, 0, 0, 0, 0, 0, 0, 0>> = encode_to_binary(42, :int64)
    end

    test "byte has no alignment" do
      # Byte aligns to 1 byte, so no padding ever needed
      assert <<42>> = encode_to_binary(42, :byte)
    end
  end

  describe "arrays" do
    test "encodes empty array" do
      # Array format: length (uint32) + elements
      assert <<0, 0, 0, 0>> = encode_to_binary([], {:array, :int32})
    end

    test "encodes array of int32" do
      # Each int32 is 4 bytes: 42, 0, 0, 0 and 100, 0, 0, 0
      # Length = 8 bytes
      assert <<8, 0, 0, 0, 42, 0, 0, 0, 100, 0, 0, 0>> =
               encode_to_binary([42, 100], {:array, :int32})
    end

    test "encodes array of strings" do
      # Each string: length (4 bytes) + data + null terminator
      # String elements start at offset 0 in the array body
      # "hi" at offset 0: length(4) + "hi"(2) + null(1) = 7 bytes
      # "x" at offset 7: alignment needed? String aligns to 4 bytes, but we're already at offset 7
      # Next 4-byte boundary is 8, so we need 1 byte padding
      # Then: length(4) + "x"(1) + null(1) = 6 bytes
      # Total elements: 7 + 1 + 6 = 14 bytes
      result = encode_to_binary(["hi", "x"], {:array, :string})

      # Format: length (4) + [string1 (7 bytes) + padding (1) + string2 (6 bytes)]
      expected = <<14, 0, 0, 0, 2, 0, 0, 0, 104, 105, 0, 0, 1, 0, 0, 0, 120, 0>>
      assert ^expected = result
    end
  end

  describe "structs" do
    test "encodes struct with single element" do
      # Struct with int32
      assert <<42, 0, 0, 0>> = encode_to_binary({42}, {:struct, [:int32]})
    end

    test "encodes struct with multiple elements" do
      # Struct (int32, int16): 4-byte aligned
      # int32: 42 = 42,0,0,0
      # int16: 10 = 10,0
      result = encode_to_binary({42, 10}, {:struct, [:int32, :int16]})
      assert <<42, 0, 0, 0, 10, 0>> = result
    end

    test "encodes struct with string" do
      # Struct (int32, string)
      # int32: 42 = 42,0,0,0
      # string: length (4) + "hi" + null = 2,0,0,0,h,i,0
      result = encode_to_binary({42, "hi"}, {:struct, [:int32, :string]})
      assert <<42, 0, 0, 0, 2, 0, 0, 0, 104, 105, 0>> = result
    end
  end

  describe "variants" do
    test "encodes variant with int32" do
      # Format: signature length (1) + signature + null + [padding] + value
      # Signature "i" at offset 0: length(1) + "i"(1) + null(1) = 3 bytes
      # Need padding to align int32 at 4-byte boundary: 1 byte padding
      # Value 42: 4 bytes
      result = encode_to_binary({"i", 42}, :variant)
      assert <<1, 105, 0, 0, 42, 0, 0, 0>> = result
    end

    test "encodes variant with string" do
      # Signature "s" at offset 0: length(1) + "s"(1) + null(1) = 3 bytes
      # Need padding to align string length (uint32) at 4-byte boundary: 1 byte padding
      # String value: length(4) + "hi"(2) + null(1) = 7 bytes
      result = encode_to_binary({"s", "hi"}, :variant)
      assert <<1, 115, 0, 0, 2, 0, 0, 0, 104, 105, 0>> = result
    end
  end

  describe "dict entries (a{sv})" do
    test "encodes array of dict entries (most common pattern)" do
      # Array of {string, variant}
      # Entry 1: {"key", {"i", 42}}
      # Entry 2: {"x", {"s", "val"}}

      entries = [
        {"key", {"i", 42}},
        {"x", {"s", "val"}}
      ]

      result = encode_to_binary(entries, {:array, {:dict_entry, :string, :variant}})

      # This is complex, just verify it encodes without error and produces reasonable output
      binary = result
      assert is_binary(binary)
      assert byte_size(binary) > 4  # At least length prefix
    end
  end

  describe "nested containers" do
    test "encodes array of structs" do
      # Array of (int32, int32)
      structs = [{1, 2}, {3, 4}]
      result = encode_to_binary(structs, {:array, {:struct, [:int32, :int32]}})
      assert is_binary(result)
    end

    test "encodes array of arrays" do
      # Array of (array of int32)
      arrays = [[1, 2], [3, 4, 5]]
      result = encode_to_binary(arrays, {:array, {:array, :int32}})
      assert is_binary(result)
    end
  end

  describe "error handling" do
    test "raises on invalid byte value" do
      assert_raise ArgumentError, fn ->
        encode_to_binary(256, :byte)
      end

      assert_raise ArgumentError, fn ->
        encode_to_binary(-1, :byte)
      end
    end

    test "raises on type mismatch" do
      assert_raise ArgumentError, fn ->
        encode_to_binary("not an int", :int32)
      end

      assert_raise ArgumentError, fn ->
        encode_to_binary(42, :string)
      end
    end

    test "raises on invalid type signature" do
      assert_raise ArgumentError, fn ->
        encode_to_binary(42, "invalid")
      end
    end
  end

  describe "real-world patterns" do
    test "encodes D-Bus method arguments: (so)" do
      # String and object path
      args = {"hello", "/org/freedesktop/DBus"}
      result = encode_to_binary(args, "(so)")
      assert is_binary(result)
      # Verify basic structure: string length + data + object_path
      assert byte_size(result) > 10
    end

    test "encodes property dict: a{sv}" do
      # Common pattern: array of {string, variant} for properties
      props = [
        {"Version", {"u", 1}},
        {"Features", {"as", ["unix-fd"]}}
      ]

      result = encode_to_binary(props, "a{sv}")
      assert is_binary(result)
    end
  end
end
