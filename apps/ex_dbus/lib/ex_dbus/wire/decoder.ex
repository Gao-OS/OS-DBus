defmodule ExDBus.Wire.Decoder do
  @moduledoc """
  Decode D-Bus wire protocol binary format to Elixir terms.

  The inverse of `ExDBus.Wire.Encoder`. Uses binary pattern matching for decoding,
  consuming correct alignment padding before each value.

  All decode functions return `{:ok, value, rest, new_offset}` internally,
  where `rest` is the remaining binary and `new_offset` tracks position
  for alignment calculations.
  """

  alias ExDBus.Wire.Types

  @doc """
  Decode a single value from a D-Bus wire format binary.

  Returns `{:ok, value, rest}` or `{:error, reason}`.

  ## Examples

      iex> ExDBus.Wire.Decoder.decode(<<42, 0, 0, 0>>, :int32)
      {:ok, 42, <<>>}

      iex> ExDBus.Wire.Decoder.decode(<<5, 0, 0, 0, "hello", 0>>, :string)
      {:ok, "hello", <<>>}
  """
  def decode(binary, type, endianness \\ :little) do
    type = normalize_type(type)

    case decode_impl(binary, type, endianness, 0) do
      {:ok, value, rest, _offset} -> {:ok, value, rest}
      {:error, _} = error -> error
    end
  end

  @doc """
  Decode a value at a specific offset (for internal use and message decoding).

  Returns `{:ok, value, rest, new_offset}` or `{:error, reason}`.
  """
  def decode_at(binary, type, endianness, offset) do
    type = normalize_type(type)
    decode_impl(binary, type, endianness, offset)
  end

  defp normalize_type(type) when is_binary(type) do
    case Types.parse_signature(type) do
      {:ok, parsed} -> parsed
      {:error, _} -> raise ArgumentError, "Invalid type signature: #{type}"
    end
  end

  defp normalize_type(type), do: type

  # Skip alignment padding bytes
  defp consume_padding(binary, offset, alignment) do
    padding = rem(alignment - rem(offset, alignment), alignment)

    case binary do
      <<_pad::binary-size(padding), rest::binary>> ->
        {:ok, rest, offset + padding}

      _ ->
        {:error, {:insufficient_data_for_padding, byte_size(binary), padding}}
    end
  end

  # --- Basic types ---

  defp decode_impl(binary, :byte, _endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 1) do
      case rest do
        <<value::unsigned-integer-size(8), rest2::binary>> ->
          {:ok, value, rest2, offset + 1}

        _ ->
          {:error, {:insufficient_data, :byte}}
      end
    end
  end

  defp decode_impl(binary, :boolean, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 4) do
      case decode_raw_uint32(rest, endianness) do
        {:ok, 0, rest2} -> {:ok, false, rest2, offset + 4}
        {:ok, 1, rest2} -> {:ok, true, rest2, offset + 4}
        {:ok, v, _rest2} -> {:error, {:invalid_boolean, v}}
        error -> error
      end
    end
  end

  defp decode_impl(binary, :int16, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 2) do
      case {endianness, rest} do
        {:little, <<value::signed-integer-size(16)-little, rest2::binary>>} ->
          {:ok, value, rest2, offset + 2}

        {:big, <<value::signed-integer-size(16)-big, rest2::binary>>} ->
          {:ok, value, rest2, offset + 2}

        _ ->
          {:error, {:insufficient_data, :int16}}
      end
    end
  end

  defp decode_impl(binary, :uint16, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 2) do
      case {endianness, rest} do
        {:little, <<value::unsigned-integer-size(16)-little, rest2::binary>>} ->
          {:ok, value, rest2, offset + 2}

        {:big, <<value::unsigned-integer-size(16)-big, rest2::binary>>} ->
          {:ok, value, rest2, offset + 2}

        _ ->
          {:error, {:insufficient_data, :uint16}}
      end
    end
  end

  defp decode_impl(binary, :int32, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 4) do
      case {endianness, rest} do
        {:little, <<value::signed-integer-size(32)-little, rest2::binary>>} ->
          {:ok, value, rest2, offset + 4}

        {:big, <<value::signed-integer-size(32)-big, rest2::binary>>} ->
          {:ok, value, rest2, offset + 4}

        _ ->
          {:error, {:insufficient_data, :int32}}
      end
    end
  end

  defp decode_impl(binary, :uint32, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 4) do
      decode_raw_uint32_with_offset(rest, endianness, offset)
    end
  end

  defp decode_impl(binary, :int64, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 8) do
      case {endianness, rest} do
        {:little, <<value::signed-integer-size(64)-little, rest2::binary>>} ->
          {:ok, value, rest2, offset + 8}

        {:big, <<value::signed-integer-size(64)-big, rest2::binary>>} ->
          {:ok, value, rest2, offset + 8}

        _ ->
          {:error, {:insufficient_data, :int64}}
      end
    end
  end

  defp decode_impl(binary, :uint64, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 8) do
      case {endianness, rest} do
        {:little, <<value::unsigned-integer-size(64)-little, rest2::binary>>} ->
          {:ok, value, rest2, offset + 8}

        {:big, <<value::unsigned-integer-size(64)-big, rest2::binary>>} ->
          {:ok, value, rest2, offset + 8}

        _ ->
          {:error, {:insufficient_data, :uint64}}
      end
    end
  end

  defp decode_impl(binary, :double, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 8) do
      case {endianness, rest} do
        {:little, <<value::float-size(64)-little, rest2::binary>>} ->
          {:ok, value, rest2, offset + 8}

        {:big, <<value::float-size(64)-big, rest2::binary>>} ->
          {:ok, value, rest2, offset + 8}

        _ ->
          {:error, {:insufficient_data, :double}}
      end
    end
  end

  defp decode_impl(binary, :string, endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 4),
         {:ok, len, rest2} <- decode_raw_uint32(rest, endianness) do
      offset = offset + 4

      case rest2 do
        <<str::binary-size(len), 0, rest3::binary>> ->
          {:ok, str, rest3, offset + len + 1}

        _ ->
          {:error, {:insufficient_data, :string}}
      end
    end
  end

  defp decode_impl(binary, :object_path, endianness, offset) do
    # Same wire format as string
    decode_impl(binary, :string, endianness, offset)
  end

  defp decode_impl(binary, :signature, _endianness, offset) do
    with {:ok, rest, offset} <- consume_padding(binary, offset, 1) do
      case rest do
        <<len::unsigned-integer-size(8), rest2::binary>> ->
          offset = offset + 1

          case rest2 do
            <<sig::binary-size(len), 0, rest3::binary>> ->
              {:ok, sig, rest3, offset + len + 1}

            _ ->
              {:error, {:insufficient_data, :signature}}
          end

        _ ->
          {:error, {:insufficient_data, :signature}}
      end
    end
  end

  defp decode_impl(binary, :unix_fd, endianness, offset) do
    # Same wire format as uint32
    with {:ok, rest, offset} <- consume_padding(binary, offset, 4) do
      decode_raw_uint32_with_offset(rest, endianness, offset)
    end
  end

  # --- Container types ---

  defp decode_impl(binary, :variant, endianness, offset) do
    # Decode signature first
    with {:ok, sig_str, rest, offset} <- decode_impl(binary, :signature, endianness, offset),
         {:ok, val_type} <- Types.parse_signature(sig_str),
         {:ok, value, rest2, offset} <- decode_impl(rest, val_type, endianness, offset) do
      {:ok, {sig_str, value}, rest2, offset}
    end
  end

  defp decode_impl(binary, {:array, elem_type}, endianness, offset) do
    # Decode array length (uint32)
    with {:ok, rest, offset} <- consume_padding(binary, offset, 4),
         {:ok, array_len, rest2} <- decode_raw_uint32(rest, endianness) do
      offset = offset + 4

      # For struct/dict_entry arrays, we need to align to 8 bytes before the first element
      elem_align = Types.alignment(elem_type)
      {rest3, offset} =
        if elem_align > 4 do
          padding = rem(elem_align - rem(offset, elem_align), elem_align)
          <<_pad::binary-size(padding), rest3::binary>> = rest2
          {rest3, offset + padding}
        else
          {rest2, offset}
        end

      # Decode elements within the array_len byte boundary
      end_offset = offset + array_len
      decode_array_elements(rest3, elem_type, endianness, offset, end_offset, [])
    end
  end

  defp decode_impl(binary, {:struct, types}, endianness, offset) do
    # Struct starts with 8-byte alignment
    with {:ok, rest, offset} <- consume_padding(binary, offset, 8) do
      decode_struct_members(rest, types, endianness, offset, [])
    end
  end

  defp decode_impl(binary, {:dict_entry, key_type, val_type}, endianness, offset) do
    # Dict entry starts with 8-byte alignment
    with {:ok, rest, offset} <- consume_padding(binary, offset, 8),
         {:ok, key, rest2, offset} <- decode_impl(rest, key_type, endianness, offset),
         {:ok, val, rest3, offset} <- decode_impl(rest2, val_type, endianness, offset) do
      {:ok, {key, val}, rest3, offset}
    end
  end

  # --- Array element helpers ---

  defp decode_array_elements(binary, _elem_type, _endianness, offset, end_offset, acc)
       when offset >= end_offset do
    {:ok, Enum.reverse(acc), binary, offset}
  end

  defp decode_array_elements(binary, elem_type, endianness, offset, end_offset, acc) do
    case decode_impl(binary, elem_type, endianness, offset) do
      {:ok, value, rest, new_offset} ->
        decode_array_elements(rest, elem_type, endianness, new_offset, end_offset, [value | acc])

      error ->
        error
    end
  end

  # --- Struct member helpers ---

  defp decode_struct_members(binary, [], _endianness, offset, acc) do
    {:ok, List.to_tuple(Enum.reverse(acc)), binary, offset}
  end

  defp decode_struct_members(binary, [type | types], endianness, offset, acc) do
    case decode_impl(binary, type, endianness, offset) do
      {:ok, value, rest, new_offset} ->
        decode_struct_members(rest, types, endianness, new_offset, [value | acc])

      error ->
        error
    end
  end

  # --- Raw decode helpers (without offset tracking, for internal use) ---

  defp decode_raw_uint32(binary, :little) do
    case binary do
      <<value::unsigned-integer-size(32)-little, rest::binary>> -> {:ok, value, rest}
      _ -> {:error, {:insufficient_data, :uint32}}
    end
  end

  defp decode_raw_uint32(binary, :big) do
    case binary do
      <<value::unsigned-integer-size(32)-big, rest::binary>> -> {:ok, value, rest}
      _ -> {:error, {:insufficient_data, :uint32}}
    end
  end

  defp decode_raw_uint32_with_offset(binary, endianness, offset) do
    case decode_raw_uint32(binary, endianness) do
      {:ok, value, rest} -> {:ok, value, rest, offset + 4}
      error -> error
    end
  end
end
