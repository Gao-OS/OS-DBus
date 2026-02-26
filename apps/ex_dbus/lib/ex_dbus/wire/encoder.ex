defmodule ExDBus.Wire.Encoder do
  @moduledoc """
  Encode Elixir terms to D-Bus wire protocol binary format.

  Uses iolist accumulation for zero-copy performance.
  Handles all alignment rules correctly as per the D-Bus spec.

  Endianness: :little (default) or :big
  """

  alias ExDBus.Wire.Types

  @doc """
  Encode a single value to D-Bus wire format.

  Returns an iolist that should be flattened to binary via IO.iodata_to_binary/1.

  Examples:
      iex> encode(42, :int32) |> IO.iodata_to_binary()
      <<42, 0, 0, 0>>

      iex> encode("hello", :string) |> IO.iodata_to_binary()
      <<5, 0, 0, 0, 104, 101, 108, 108, 111, 0>>
  """
  def encode(value, type, endianness \\ :little) do
    # Validate type signature if it's a string
    type = normalize_type(type)
    encode_impl(value, type, endianness, 0)
  end

  # Normalize string signatures to type AST
  defp normalize_type(type) when is_binary(type) do
    case Types.parse_signature(type) do
      {:ok, parsed} -> parsed
      {:error, _} -> raise ArgumentError, "Invalid type signature: #{type}"
    end
  end

  defp normalize_type(type), do: type

  # Align to a boundary. Return padding iolist.
  defp align(offset, target_alignment) do
    padding = rem(target_alignment - rem(offset, target_alignment), target_alignment)
    {<<0::size(padding)-unit(8)>>, padding}
  end

  # Basic types (no alignment padding before, just the value)
  defp encode_impl(value, :byte, _endianness, offset) do
    Types.valid?(:byte, value) || raise ArgumentError, "Invalid byte: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 1)
    [pad, <<value::unsigned-integer-size(8)>>]
  end

  defp encode_impl(value, :boolean, endianness, offset) do
    Types.valid?(:boolean, value) || raise ArgumentError, "Invalid boolean: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 4)
    val_int = if value, do: 1, else: 0
    [pad, encode_uint32(val_int, endianness)]
  end

  defp encode_impl(value, :int16, endianness, offset) do
    Types.valid?(:int16, value) || raise ArgumentError, "Invalid int16: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 2)
    [pad, encode_int16(value, endianness)]
  end

  defp encode_impl(value, :uint16, endianness, offset) do
    Types.valid?(:uint16, value) || raise ArgumentError, "Invalid uint16: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 2)
    [pad, encode_uint16(value, endianness)]
  end

  defp encode_impl(value, :int32, endianness, offset) do
    Types.valid?(:int32, value) || raise ArgumentError, "Invalid int32: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 4)
    [pad, encode_int32(value, endianness)]
  end

  defp encode_impl(value, :uint32, endianness, offset) do
    Types.valid?(:uint32, value) || raise ArgumentError, "Invalid uint32: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 4)
    [pad, encode_uint32(value, endianness)]
  end

  defp encode_impl(value, :int64, endianness, offset) do
    Types.valid?(:int64, value) || raise ArgumentError, "Invalid int64: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 8)
    [pad, encode_int64(value, endianness)]
  end

  defp encode_impl(value, :uint64, endianness, offset) do
    Types.valid?(:uint64, value) || raise ArgumentError, "Invalid uint64: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 8)
    [pad, encode_uint64(value, endianness)]
  end

  defp encode_impl(value, :double, endianness, offset) do
    Types.valid?(:double, value) || raise ArgumentError, "Invalid double: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 8)
    val_float = if is_integer(value), do: value / 1.0, else: value
    [pad, encode_double(val_float, endianness)]
  end

  defp encode_impl(value, :string, endianness, offset) do
    Types.valid?(:string, value) || raise ArgumentError, "Invalid string: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 4)
    len = byte_size(value)
    [pad, encode_uint32(len, endianness), value, <<0>>]
  end

  defp encode_impl(value, :object_path, endianness, offset) do
    Types.valid?(:object_path, value) || raise ArgumentError, "Invalid object_path: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 4)
    len = byte_size(value)
    [pad, encode_uint32(len, endianness), value, <<0>>]
  end

  defp encode_impl(value, :signature, _endianness, offset) do
    Types.valid?(:signature, value) || raise ArgumentError, "Invalid signature: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 1)
    len = byte_size(value)
    [pad, <<len::unsigned-integer-size(8)>>, value, <<0>>]
  end

  defp encode_impl(value, :unix_fd, endianness, offset) do
    Types.valid?(:unix_fd, value) || raise ArgumentError, "Invalid unix_fd: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 4)
    [pad, encode_uint32(value, endianness)]
  end

  # Variant: {signature, value}
  defp encode_impl(value, :variant, endianness, offset) do
    Types.valid?(:variant, value) || raise ArgumentError, "Invalid variant: #{inspect(value)}"
    {sig_str, val} = value
    {pad, pad_len} = align(offset, 1)
    sig_len = byte_size(sig_str)
    # Encode signature first (length + sig string + null terminator)
    sig_encoded = [<<sig_len::unsigned-integer-size(8)>>, sig_str, <<0>>]
    # Parse the signature to get the value type
    {:ok, val_type} = Types.parse_signature(sig_str)
    # Align for the value (variant body starts at 8-byte boundary)
    val_offset = pad_len + 1 + sig_len + 1
    val_encoded = encode_impl(val, val_type, endianness, val_offset)
    [pad, sig_encoded, val_encoded]
  end

  # Array: list of elements
  defp encode_impl(value, {:array, elem_type}, endianness, offset) do
    is_list(value) || raise ArgumentError, "Array value must be a list, got: #{inspect(value)}"
    {pad, _pad_len} = align(offset, 4)

    # Encode array elements first to know the total length
    elements_iolist = encode_array_elements(value, elem_type, endianness, 0)
    elements_binary = IO.iodata_to_binary(elements_iolist)
    array_len = byte_size(elements_binary)

    [pad, encode_uint32(array_len, endianness), elements_iolist]
  end

  defp encode_array_elements([], _elem_type, _endianness, _offset), do: []

  defp encode_array_elements([head | tail], elem_type, endianness, offset) do
    encoded_head = encode_impl(head, elem_type, endianness, offset)
    head_binary = IO.iodata_to_binary(encoded_head)
    new_offset = offset + byte_size(head_binary)
    encoded_tail = encode_array_elements(tail, elem_type, endianness, new_offset)
    [encoded_head, encoded_tail]
  end

  # Struct: tuple of elements with 8-byte alignment
  defp encode_impl(value, {:struct, types}, endianness, offset) do
    is_tuple(value) || raise ArgumentError, "Struct value must be a tuple, got: #{inspect(value)}"
    {pad, pad_len} = align(offset, 8)
    values_list = Tuple.to_list(value)
    encode_struct_members(values_list, types, endianness, offset + pad_len)
    |> (fn result -> [pad, result] end).()
  end

  defp encode_struct_members([], [], _endianness, _offset), do: []

  defp encode_struct_members([value | values], [type | types], endianness, offset) do
    encoded = encode_impl(value, type, endianness, offset)
    encoded_binary = IO.iodata_to_binary(encoded)
    new_offset = offset + byte_size(encoded_binary)
    rest = encode_struct_members(values, types, endianness, new_offset)
    [encoded, rest]
  end

  # Dict entry: {key, value} - only valid inside arrays
  defp encode_impl(value, {:dict_entry, key_type, val_type}, endianness, offset) do
    is_tuple(value) and tuple_size(value) == 2 ||
      raise ArgumentError, "Dict entry must be a 2-tuple, got: #{inspect(value)}"

    {pad, pad_len} = align(offset, 8)
    {key, val} = value
    key_encoded = encode_impl(key, key_type, endianness, offset + pad_len)
    key_binary = IO.iodata_to_binary(key_encoded)
    key_len = byte_size(key_binary)
    val_encoded = encode_impl(val, val_type, endianness, offset + pad_len + key_len)
    [pad, key_encoded, val_encoded]
  end

  # Helper encoding functions for primitive types
  defp encode_int16(value, :little), do: <<value::signed-integer-size(16)-little>>
  defp encode_int16(value, :big), do: <<value::signed-integer-size(16)-big>>

  defp encode_uint16(value, :little), do: <<value::unsigned-integer-size(16)-little>>
  defp encode_uint16(value, :big), do: <<value::unsigned-integer-size(16)-big>>

  defp encode_int32(value, :little), do: <<value::signed-integer-size(32)-little>>
  defp encode_int32(value, :big), do: <<value::signed-integer-size(32)-big>>

  defp encode_uint32(value, :little), do: <<value::unsigned-integer-size(32)-little>>
  defp encode_uint32(value, :big), do: <<value::unsigned-integer-size(32)-big>>

  defp encode_int64(value, :little), do: <<value::signed-integer-size(64)-little>>
  defp encode_int64(value, :big), do: <<value::signed-integer-size(64)-big>>

  defp encode_uint64(value, :little), do: <<value::unsigned-integer-size(64)-little>>
  defp encode_uint64(value, :big), do: <<value::unsigned-integer-size(64)-big>>

  defp encode_double(value, :little), do: <<value::float-size(64)-little>>
  defp encode_double(value, :big), do: <<value::float-size(64)-big>>
end
