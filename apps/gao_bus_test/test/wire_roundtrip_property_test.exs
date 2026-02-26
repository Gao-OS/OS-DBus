defmodule GaoBusTest.WireRoundtripPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ExDBus.Wire.{Encoder, Decoder}

  defp roundtrip(value, type, endianness \\ :little) do
    encoded = Encoder.encode(value, type, endianness) |> IO.iodata_to_binary()
    {:ok, decoded, rest} = Decoder.decode(encoded, type, endianness)
    assert rest == <<>>, "Unexpected trailing data after decode"
    decoded
  end

  # --- StreamData generators for D-Bus types ---

  defp gen_byte, do: integer(0..255)
  defp gen_boolean, do: boolean()
  defp gen_int16, do: integer(-32768..32767)
  defp gen_uint16, do: integer(0..65535)
  defp gen_int32, do: integer(-2_147_483_648..2_147_483_647)
  defp gen_uint32, do: integer(0..4_294_967_295)
  defp gen_int64, do: integer(-9_223_372_036_854_775_808..9_223_372_036_854_775_807)
  defp gen_uint64, do: integer(0..18_446_744_073_709_551_615)

  defp gen_double do
    float(min: -1.0e100, max: 1.0e100)
  end

  defp gen_dbus_string do
    string(:printable, min_length: 0, max_length: 100)
  end

  defp gen_object_path do
    one_of([
      constant("/"),
      bind(list_of(string(:alphanumeric, min_length: 1, max_length: 10), min_length: 1, max_length: 5), fn segments ->
        constant("/" <> Enum.join(segments, "/"))
      end)
    ])
  end

  describe "property-based roundtrip: basic types" do
    property "byte roundtrips" do
      check all value <- gen_byte() do
        assert roundtrip(value, :byte) == value
      end
    end

    property "boolean roundtrips" do
      check all value <- gen_boolean() do
        assert roundtrip(value, :boolean) == value
      end
    end

    property "int16 roundtrips" do
      check all value <- gen_int16() do
        assert roundtrip(value, :int16) == value
      end
    end

    property "uint16 roundtrips" do
      check all value <- gen_uint16() do
        assert roundtrip(value, :uint16) == value
      end
    end

    property "int32 roundtrips" do
      check all value <- gen_int32() do
        assert roundtrip(value, :int32) == value
      end
    end

    property "uint32 roundtrips" do
      check all value <- gen_uint32() do
        assert roundtrip(value, :uint32) == value
      end
    end

    property "int64 roundtrips" do
      check all value <- gen_int64() do
        assert roundtrip(value, :int64) == value
      end
    end

    property "uint64 roundtrips" do
      check all value <- gen_uint64() do
        assert roundtrip(value, :uint64) == value
      end
    end

    property "double roundtrips" do
      check all value <- gen_double() do
        assert roundtrip(value, :double) == value
      end
    end

    property "string roundtrips" do
      check all value <- gen_dbus_string() do
        assert roundtrip(value, :string) == value
      end
    end

    property "object_path roundtrips" do
      check all value <- gen_object_path() do
        assert roundtrip(value, :object_path) == value
      end
    end
  end

  describe "property-based roundtrip: containers" do
    property "array of int32 roundtrips" do
      check all values <- list_of(gen_int32(), min_length: 0, max_length: 20) do
        assert roundtrip(values, {:array, :int32}) == values
      end
    end

    property "array of strings roundtrips" do
      check all values <- list_of(gen_dbus_string(), min_length: 0, max_length: 10) do
        assert roundtrip(values, {:array, :string}) == values
      end
    end

    property "array of bytes roundtrips" do
      check all values <- list_of(gen_byte(), min_length: 0, max_length: 50) do
        assert roundtrip(values, {:array, :byte}) == values
      end
    end

    property "struct (int32, string) roundtrips" do
      check all i <- gen_int32(), s <- gen_dbus_string() do
        assert roundtrip({i, s}, {:struct, [:int32, :string]}) == {i, s}
      end
    end

    property "struct (byte, uint16, int64) roundtrips" do
      check all b <- gen_byte(), q <- gen_uint16(), x <- gen_int64() do
        assert roundtrip({b, q, x}, {:struct, [:byte, :uint16, :int64]}) == {b, q, x}
      end
    end
  end

  describe "property-based roundtrip: variants" do
    property "variant with int32 roundtrips" do
      check all value <- gen_int32() do
        assert roundtrip({"i", value}, :variant) == {"i", value}
      end
    end

    property "variant with string roundtrips" do
      check all value <- gen_dbus_string() do
        assert roundtrip({"s", value}, :variant) == {"s", value}
      end
    end

    property "variant with boolean roundtrips" do
      check all value <- gen_boolean() do
        assert roundtrip({"b", value}, :variant) == {"b", value}
      end
    end
  end

  describe "property-based roundtrip: a{sv}" do
    property "a{sv} with int32 values roundtrips" do
      check all entries <-
                  list_of(
                    tuple({gen_dbus_string(), map(gen_int32(), fn v -> {"i", v} end)}),
                    min_length: 0,
                    max_length: 10
                  ) do
        type = {:array, {:dict_entry, :string, :variant}}
        assert roundtrip(entries, type) == entries
      end
    end
  end

  describe "property-based roundtrip: endianness" do
    property "int32 roundtrips with random endianness" do
      check all value <- gen_int32(), endianness <- member_of([:little, :big]) do
        assert roundtrip(value, :int32, endianness) == value
      end
    end

    property "string roundtrips with random endianness" do
      check all value <- gen_dbus_string(), endianness <- member_of([:little, :big]) do
        assert roundtrip(value, :string, endianness) == value
      end
    end

    property "array of uint32 roundtrips with random endianness" do
      check all values <- list_of(gen_uint32(), min_length: 0, max_length: 10),
                endianness <- member_of([:little, :big]) do
        assert roundtrip(values, {:array, :uint32}, endianness) == values
      end
    end
  end
end
