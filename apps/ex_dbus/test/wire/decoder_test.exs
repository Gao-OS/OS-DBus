defmodule ExDBus.Wire.DecoderTest do
  use ExUnit.Case
  alias ExDBus.Wire.{Decoder, Encoder}

  doctest Decoder

  defp encode_to_binary(value, type, endianness \\ :little) do
    Encoder.encode(value, type, endianness) |> IO.iodata_to_binary()
  end

  describe "basic types - little endian" do
    test "decodes byte" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<42>>, :byte)
      assert {:ok, 0, <<>>} = Decoder.decode(<<0>>, :byte)
      assert {:ok, 255, <<>>} = Decoder.decode(<<255>>, :byte)
    end

    test "decodes byte with trailing data" do
      assert {:ok, 42, <<99>>} = Decoder.decode(<<42, 99>>, :byte)
    end

    test "decodes boolean" do
      assert {:ok, true, <<>>} = Decoder.decode(<<1, 0, 0, 0>>, :boolean)
      assert {:ok, false, <<>>} = Decoder.decode(<<0, 0, 0, 0>>, :boolean)
    end

    test "rejects invalid boolean" do
      assert {:error, {:invalid_boolean, 2}} = Decoder.decode(<<2, 0, 0, 0>>, :boolean)
    end

    test "decodes int16" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<42, 0>>, :int16)
      assert {:ok, -32768, <<>>} = Decoder.decode(<<0, 128>>, :int16)
      assert {:ok, 32767, <<>>} = Decoder.decode(<<255, 127>>, :int16)
    end

    test "decodes uint16" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<42, 0>>, :uint16)
      assert {:ok, 65535, <<>>} = Decoder.decode(<<255, 255>>, :uint16)
    end

    test "decodes int32" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<42, 0, 0, 0>>, :int32)
      assert {:ok, -1, <<>>} = Decoder.decode(<<255, 255, 255, 255>>, :int32)
      assert {:ok, -2_147_483_648, <<>>} = Decoder.decode(<<0, 0, 0, 128>>, :int32)
    end

    test "decodes uint32" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<42, 0, 0, 0>>, :uint32)
      assert {:ok, 4_294_967_295, <<>>} = Decoder.decode(<<255, 255, 255, 255>>, :uint32)
    end

    test "decodes int64" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<42, 0, 0, 0, 0, 0, 0, 0>>, :int64)
      assert {:ok, -1, <<>>} = Decoder.decode(<<255, 255, 255, 255, 255, 255, 255, 255>>, :int64)
    end

    test "decodes uint64" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<42, 0, 0, 0, 0, 0, 0, 0>>, :uint64)
    end

    test "decodes double" do
      bin = encode_to_binary(3.14, :double)
      assert {:ok, val, <<>>} = Decoder.decode(bin, :double)
      assert_in_delta val, 3.14, 0.001
    end

    test "decodes string" do
      assert {:ok, "hello", <<>>} = Decoder.decode(<<5, 0, 0, 0, "hello", 0>>, :string)
      assert {:ok, "", <<>>} = Decoder.decode(<<0, 0, 0, 0, 0>>, :string)
    end

    test "decodes object_path" do
      bin = encode_to_binary("/org/freedesktop/DBus", :object_path)
      assert {:ok, "/org/freedesktop/DBus", <<>>} = Decoder.decode(bin, :object_path)
    end

    test "decodes signature" do
      assert {:ok, "i", <<>>} = Decoder.decode(<<1, "i", 0>>, :signature)
      assert {:ok, "ai", <<>>} = Decoder.decode(<<2, "ai", 0>>, :signature)
    end

    test "decodes unix_fd" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<42, 0, 0, 0>>, :unix_fd)
    end
  end

  describe "basic types - big endian" do
    test "decodes int32 big endian" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<0, 0, 0, 42>>, :int32, :big)
    end

    test "decodes uint32 big endian" do
      assert {:ok, 42, <<>>} = Decoder.decode(<<0, 0, 0, 42>>, :uint32, :big)
    end

    test "decodes string big endian" do
      assert {:ok, "hi", <<>>} = Decoder.decode(<<0, 0, 0, 2, "hi", 0>>, :string, :big)
    end
  end

  describe "arrays" do
    test "decodes empty array" do
      bin = encode_to_binary([], {:array, :int32})
      assert {:ok, [], <<>>} = Decoder.decode(bin, {:array, :int32})
    end

    test "decodes array of int32" do
      bin = encode_to_binary([42, 100], {:array, :int32})
      assert {:ok, [42, 100], <<>>} = Decoder.decode(bin, {:array, :int32})
    end

    test "decodes array of strings" do
      bin = encode_to_binary(["hello", "world"], {:array, :string})
      assert {:ok, ["hello", "world"], <<>>} = Decoder.decode(bin, {:array, :string})
    end

    test "decodes array of bytes" do
      bin = encode_to_binary([1, 2, 3, 4, 5], {:array, :byte})
      assert {:ok, [1, 2, 3, 4, 5], <<>>} = Decoder.decode(bin, {:array, :byte})
    end
  end

  describe "structs" do
    test "decodes struct with single element" do
      bin = encode_to_binary({42}, {:struct, [:int32]})
      assert {:ok, {42}, <<>>} = Decoder.decode(bin, {:struct, [:int32]})
    end

    test "decodes struct with multiple elements" do
      bin = encode_to_binary({42, "hello", true}, {:struct, [:int32, :string, :boolean]})
      assert {:ok, {42, "hello", true}, <<>>} = Decoder.decode(bin, {:struct, [:int32, :string, :boolean]})
    end

    test "decodes struct with nested array" do
      bin = encode_to_binary({42, [1, 2, 3]}, {:struct, [:int32, {:array, :int32}]})
      assert {:ok, {42, [1, 2, 3]}, <<>>} = Decoder.decode(bin, {:struct, [:int32, {:array, :int32}]})
    end
  end

  describe "variants" do
    test "decodes variant with int32" do
      bin = encode_to_binary({"i", 42}, :variant)
      assert {:ok, {"i", 42}, <<>>} = Decoder.decode(bin, :variant)
    end

    test "decodes variant with string" do
      bin = encode_to_binary({"s", "hello"}, :variant)
      assert {:ok, {"s", "hello"}, <<>>} = Decoder.decode(bin, :variant)
    end

    test "decodes variant with array" do
      bin = encode_to_binary({"ai", [1, 2, 3]}, :variant)
      assert {:ok, {"ai", [1, 2, 3]}, <<>>} = Decoder.decode(bin, :variant)
    end
  end

  describe "dict entries (a{sv})" do
    test "decodes array of dict entries" do
      entries = [
        {"key1", {"i", 42}},
        {"key2", {"s", "value"}}
      ]

      bin = encode_to_binary(entries, {:array, {:dict_entry, :string, :variant}})
      assert {:ok, decoded, <<>>} = Decoder.decode(bin, {:array, {:dict_entry, :string, :variant}})

      assert [{"key1", {"i", 42}}, {"key2", {"s", "value"}}] = decoded
    end

    test "decodes empty dict" do
      bin = encode_to_binary([], {:array, {:dict_entry, :string, :variant}})
      assert {:ok, [], <<>>} = Decoder.decode(bin, {:array, {:dict_entry, :string, :variant}})
    end
  end

  describe "nested containers" do
    test "decodes array of structs" do
      structs = [{1, "a"}, {2, "b"}]
      type = {:array, {:struct, [:int32, :string]}}

      bin = encode_to_binary(structs, type)
      assert {:ok, ^structs, <<>>} = Decoder.decode(bin, type)
    end

    test "decodes struct with variant containing array" do
      value = {42, {"ai", [10, 20, 30]}}
      type = {:struct, [:int32, :variant]}

      bin = encode_to_binary(value, type)
      assert {:ok, ^value, <<>>} = Decoder.decode(bin, type)
    end
  end

  describe "error handling" do
    test "returns error on insufficient data" do
      assert {:error, _} = Decoder.decode(<<42>>, :int32)
      assert {:error, _} = Decoder.decode(<<>>, :byte)
      assert {:error, _} = Decoder.decode(<<1, 0>>, :int64)
    end
  end
end
