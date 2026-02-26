defmodule ExDBus.Wire.RoundtripTest do
  use ExUnit.Case

  alias ExDBus.Wire.{Encoder, Decoder}

  # Encode then decode and verify equality
  defp roundtrip(value, type, endianness \\ :little) do
    encoded = Encoder.encode(value, type, endianness) |> IO.iodata_to_binary()
    {:ok, decoded, rest} = Decoder.decode(encoded, type, endianness)
    assert rest == <<>>, "Unexpected trailing data after decode"
    decoded
  end

  describe "basic type roundtrips" do
    test "byte values" do
      for v <- [0, 1, 42, 127, 255] do
        assert roundtrip(v, :byte) == v
      end
    end

    test "boolean values" do
      assert roundtrip(true, :boolean) == true
      assert roundtrip(false, :boolean) == false
    end

    test "int16 values" do
      for v <- [-32768, -1, 0, 1, 32767] do
        assert roundtrip(v, :int16) == v
      end
    end

    test "uint16 values" do
      for v <- [0, 1, 255, 32768, 65535] do
        assert roundtrip(v, :uint16) == v
      end
    end

    test "int32 values" do
      for v <- [-2_147_483_648, -1, 0, 1, 42, 2_147_483_647] do
        assert roundtrip(v, :int32) == v
      end
    end

    test "uint32 values" do
      for v <- [0, 1, 42, 2_147_483_648, 4_294_967_295] do
        assert roundtrip(v, :uint32) == v
      end
    end

    test "int64 values" do
      for v <- [-9_223_372_036_854_775_808, -1, 0, 1, 9_223_372_036_854_775_807] do
        assert roundtrip(v, :int64) == v
      end
    end

    test "uint64 values" do
      for v <- [0, 1, 18_446_744_073_709_551_615] do
        assert roundtrip(v, :uint64) == v
      end
    end

    test "double values" do
      for v <- [0.0, 1.0, -1.0, 3.14159, 1.0e100, -1.0e-100] do
        assert roundtrip(v, :double) == v
      end
    end

    test "string values" do
      for v <- ["", "hello", "Hello, World!", "unicode: \u00e9\u00e8\u00ea", String.duplicate("x", 1000)] do
        assert roundtrip(v, :string) == v
      end
    end

    test "object path values" do
      for v <- ["/", "/org", "/org/freedesktop/DBus", "/a/b/c/d/e"] do
        assert roundtrip(v, :object_path) == v
      end
    end

    test "signature values" do
      for v <- ["i", "s", "ai", "a{sv}", "(isi)"] do
        assert roundtrip(v, :signature) == v
      end
    end

    test "unix fd values" do
      for v <- [0, 1, 42, 999] do
        assert roundtrip(v, :unix_fd) == v
      end
    end
  end

  describe "endianness roundtrips" do
    test "int32 in both endianness" do
      for v <- [-1, 0, 42, 2_147_483_647] do
        assert roundtrip(v, :int32, :little) == v
        assert roundtrip(v, :int32, :big) == v
      end
    end

    test "string in both endianness" do
      for v <- ["", "hello", "test string"] do
        assert roundtrip(v, :string, :little) == v
        assert roundtrip(v, :string, :big) == v
      end
    end

    test "array in both endianness" do
      list = [1, 2, 3, 100, 999]
      assert roundtrip(list, {:array, :int32}, :little) == list
      assert roundtrip(list, {:array, :int32}, :big) == list
    end

    test "double in both endianness" do
      for v <- [3.14, -1.0e50, 0.0] do
        assert roundtrip(v, :double, :little) == v
        assert roundtrip(v, :double, :big) == v
      end
    end
  end

  describe "array roundtrips" do
    test "empty arrays" do
      assert roundtrip([], {:array, :int32}) == []
      assert roundtrip([], {:array, :string}) == []
      assert roundtrip([], {:array, :byte}) == []
    end

    test "array of int32" do
      values = [1, -1, 0, 42, 2_147_483_647]
      assert roundtrip(values, {:array, :int32}) == values
    end

    test "array of strings" do
      values = ["hello", "world", "", "test"]
      assert roundtrip(values, {:array, :string}) == values
    end

    test "array of bytes" do
      values = [0, 1, 42, 127, 255]
      assert roundtrip(values, {:array, :byte}) == values
    end

    test "array of uint64" do
      values = [0, 1, 18_446_744_073_709_551_615]
      assert roundtrip(values, {:array, :uint64}) == values
    end

    test "nested array (array of array)" do
      values = [[1, 2], [3, 4, 5], []]
      assert roundtrip(values, {:array, {:array, :int32}}) == values
    end
  end

  describe "struct roundtrips" do
    test "single element struct" do
      assert roundtrip({42}, {:struct, [:int32]}) == {42}
    end

    test "multi-element struct" do
      value = {42, "hello", true}
      type = {:struct, [:int32, :string, :boolean]}
      assert roundtrip(value, type) == value
    end

    test "struct with all basic types" do
      value = {255, true, 1000, 50000, -42, 100_000, 999, 18_446_744_073_709_551_615, 3.14, "test", "/org/test", 7}
      type = {:struct, [:byte, :boolean, :int16, :uint16, :int32, :uint32, :int64, :uint64, :double, :string, :object_path, :unix_fd]}
      assert roundtrip(value, type) == value
    end

    test "struct with nested array" do
      value = {42, [1, 2, 3]}
      type = {:struct, [:int32, {:array, :int32}]}
      assert roundtrip(value, type) == value
    end

    test "struct containing struct" do
      value = {1, {2, "inner"}}
      type = {:struct, [:int32, {:struct, [:int32, :string]}]}
      assert roundtrip(value, type) == value
    end
  end

  describe "variant roundtrips" do
    test "variant with basic types" do
      assert roundtrip({"i", 42}, :variant) == {"i", 42}
      assert roundtrip({"s", "hello"}, :variant) == {"s", "hello"}
      assert roundtrip({"b", true}, :variant) == {"b", true}
      assert roundtrip({"y", 255}, :variant) == {"y", 255}
      assert roundtrip({"d", 3.14}, :variant) == {"d", 3.14}
      assert roundtrip({"u", 0}, :variant) == {"u", 0}
    end

    test "variant with array" do
      assert roundtrip({"ai", [1, 2, 3]}, :variant) == {"ai", [1, 2, 3]}
      assert roundtrip({"as", ["a", "b"]}, :variant) == {"as", ["a", "b"]}
    end

    test "variant with empty array" do
      assert roundtrip({"ai", []}, :variant) == {"ai", []}
    end
  end

  describe "dict entry (a{sv}) roundtrips" do
    test "empty dict" do
      type = {:array, {:dict_entry, :string, :variant}}
      assert roundtrip([], type) == []
    end

    test "dict with int values" do
      entries = [{"a", {"i", 1}}, {"b", {"i", 2}}]
      type = {:array, {:dict_entry, :string, :variant}}
      assert roundtrip(entries, type) == entries
    end

    test "dict with mixed variant types" do
      entries = [
        {"int_val", {"i", 42}},
        {"str_val", {"s", "hello"}},
        {"bool_val", {"b", true}},
        {"byte_val", {"y", 255}}
      ]
      type = {:array, {:dict_entry, :string, :variant}}
      assert roundtrip(entries, type) == entries
    end

    test "dict with uint32 keys" do
      entries = [{1, "one"}, {2, "two"}, {3, "three"}]
      type = {:array, {:dict_entry, :uint32, :string}}
      assert roundtrip(entries, type) == entries
    end
  end

  describe "complex nested type roundtrips" do
    test "array of structs" do
      value = [{1, "a"}, {2, "b"}, {3, "c"}]
      type = {:array, {:struct, [:int32, :string]}}
      assert roundtrip(value, type) == value
    end

    test "nested array of structs with inner arrays" do
      value = [{1, "a", [10, 20]}, {2, "b", [30]}]
      type = {:array, {:struct, [:int32, :string, {:array, :int32}]}}
      assert roundtrip(value, type) == value
    end

    test "struct containing variant with nested array" do
      value = {"/org/test", "TestInterface", {"ai", [1, 2, 3]}}
      type = {:struct, [:object_path, :string, :variant]}
      assert roundtrip(value, type) == value
    end

    test "deeply nested: array of structs with array of variants" do
      value = [
        {1, [{"i", 10}, {"s", "x"}]},
        {2, [{"b", false}]}
      ]
      type = {:array, {:struct, [:int32, {:array, :variant}]}}
      assert roundtrip(value, type) == value
    end

    test "D-Bus properties format: a{sv} with complex values" do
      entries = [
        {"Name", {"s", "MyService"}},
        {"Version", {"u", 1}},
        {"Features", {"ai", [1, 2, 3]}},
        {"Active", {"b", true}}
      ]
      type = {:array, {:dict_entry, :string, :variant}}
      assert roundtrip(entries, type) == entries
    end
  end
end
