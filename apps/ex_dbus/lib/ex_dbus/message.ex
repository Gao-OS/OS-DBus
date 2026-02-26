defmodule ExDBus.Message do
  @moduledoc """
  D-Bus message struct and marshalling.

  A D-Bus message consists of a fixed header, header fields array, and body.

  ## Header format

      byte        endianness ('l' = little, 'B' = big)
      byte        message_type (1=method_call, 2=method_return, 3=error, 4=signal)
      byte        flags (0x1=no_reply_expected, 0x2=no_auto_start)
      byte        protocol_version (1)
      uint32      body_length
      uint32      serial
      array       header_fields (typed key-value pairs)
      padding     align to 8 bytes

  ## Header field codes

      1 = PATH         (object_path, required for method_call/signal)
      2 = INTERFACE    (string)
      3 = MEMBER       (string, required for method_call/signal)
      4 = ERROR_NAME   (string, required for error)
      5 = REPLY_SERIAL (uint32, required for method_return/error)
      6 = DESTINATION  (string)
      7 = SENDER       (string)
      8 = SIGNATURE    (signature, body type signature)
      9 = UNIX_FDS     (uint32)
  """

  alias ExDBus.Wire.{Encoder, Decoder, Types}

  @protocol_version 1

  # Message types
  @type_method_call 1
  @type_method_return 2
  @type_error 3
  @type_signal 4

  # Header field codes
  @field_path 1
  @field_interface 2
  @field_member 3
  @field_error_name 4
  @field_reply_serial 5
  @field_destination 6
  @field_sender 7
  @field_signature 8
  @field_unix_fds 9

  defstruct [
    :type,
    :serial,
    flags: 0,
    path: nil,
    interface: nil,
    member: nil,
    error_name: nil,
    reply_serial: nil,
    destination: nil,
    sender: nil,
    signature: nil,
    unix_fds: nil,
    body: []
  ]

  @type message_type :: :method_call | :method_return | :error | :signal
  @type t :: %__MODULE__{
          type: message_type(),
          serial: non_neg_integer(),
          flags: non_neg_integer(),
          path: String.t() | nil,
          interface: String.t() | nil,
          member: String.t() | nil,
          error_name: String.t() | nil,
          reply_serial: non_neg_integer() | nil,
          destination: String.t() | nil,
          sender: String.t() | nil,
          signature: String.t() | nil,
          unix_fds: non_neg_integer() | nil,
          body: list()
        }

  @doc """
  Create a method_call message.
  """
  def method_call(path, interface, member, opts \\ []) do
    %__MODULE__{
      type: :method_call,
      serial: Keyword.get(opts, :serial, 0),
      flags: Keyword.get(opts, :flags, 0),
      path: path,
      interface: interface,
      member: member,
      destination: Keyword.get(opts, :destination),
      signature: Keyword.get(opts, :signature),
      body: Keyword.get(opts, :body, [])
    }
  end

  @doc """
  Create a method_return message.
  """
  def method_return(reply_serial, opts \\ []) do
    %__MODULE__{
      type: :method_return,
      serial: Keyword.get(opts, :serial, 0),
      flags: Keyword.get(opts, :flags, 0),
      reply_serial: reply_serial,
      destination: Keyword.get(opts, :destination),
      signature: Keyword.get(opts, :signature),
      body: Keyword.get(opts, :body, [])
    }
  end

  @doc """
  Create an error message.
  """
  def error(error_name, reply_serial, opts \\ []) do
    %__MODULE__{
      type: :error,
      serial: Keyword.get(opts, :serial, 0),
      flags: Keyword.get(opts, :flags, 0),
      error_name: error_name,
      reply_serial: reply_serial,
      destination: Keyword.get(opts, :destination),
      signature: Keyword.get(opts, :signature),
      body: Keyword.get(opts, :body, [])
    }
  end

  @doc """
  Create a signal message.
  """
  def signal(path, interface, member, opts \\ []) do
    %__MODULE__{
      type: :signal,
      serial: Keyword.get(opts, :serial, 0),
      flags: Keyword.get(opts, :flags, 0),
      path: path,
      interface: interface,
      member: member,
      destination: Keyword.get(opts, :destination),
      signature: Keyword.get(opts, :signature),
      body: Keyword.get(opts, :body, [])
    }
  end

  @doc """
  Encode a message struct to D-Bus wire format binary.

  Returns iodata suitable for sending over a transport.
  """
  def encode_message(%__MODULE__{} = msg, endianness \\ :little) do
    endian_byte = endianness_to_byte(endianness)
    type_byte = type_to_byte(msg.type)

    # Encode body first to know body_length (body is at offset 0 relative to body start)
    body_binary = encode_body(msg.body, msg.signature, endianness)
    body_length = byte_size(body_binary)

    # Fixed header: endianness(1) + type(1) + flags(1) + version(1) + body_len(4) + serial(4) = 12 bytes
    fixed_header = [
      <<endian_byte::8>>,
      <<type_byte::8>>,
      <<msg.flags::8>>,
      <<@protocol_version::8>>,
      encode_uint32(body_length, endianness),
      encode_uint32(msg.serial, endianness)
    ]

    # Encode header fields array at offset 12 (after fixed header)
    # This ensures alignment is calculated relative to message start
    fields = build_header_fields(msg)
    {fields_iodata, offset_after_fields} =
      Encoder.encode_at(fields, {:array, {:struct, [:byte, :variant]}}, endianness, 12)
    fields_binary = IO.iodata_to_binary(fields_iodata)

    # Align body to 8-byte boundary
    body_padding_len = rem(8 - rem(offset_after_fields, 8), 8)
    body_padding = <<0::size(body_padding_len)-unit(8)>>

    IO.iodata_to_binary([fixed_header, fields_binary, body_padding, body_binary])
  end

  @doc """
  Decode a D-Bus message from binary data.

  Returns `{:ok, message, rest}` or `{:error, reason}`.
  """
  def decode_message(binary) when byte_size(binary) < 16 do
    {:error, :insufficient_data}
  end

  def decode_message(binary) do
    # Read first byte to determine endianness
    <<endian_byte::8, rest::binary>> = binary

    endianness =
      case endian_byte do
        ?l -> :little
        ?B -> :big
        _ -> :invalid
      end

    if endianness == :invalid do
      {:error, {:invalid_endianness, endian_byte}}
    else
      decode_message_with_endianness(rest, endianness)
    end
  end

  # --- Private encode helpers ---

  defp encode_body([], _signature, _endianness), do: <<>>

  defp encode_body(body, signature, endianness) when is_binary(signature) do
    {:ok, types} = Types.parse_types(signature)
    encode_body_values(body, types, endianness, 0)
    |> IO.iodata_to_binary()
  end

  defp encode_body(_body, nil, _endianness), do: <<>>

  defp encode_body_values([], [], _endianness, _offset), do: []

  defp encode_body_values([value | values], [type | types], endianness, offset) do
    {encoded, new_offset} = Encoder.encode_at(value, type, endianness, offset)
    [encoded | encode_body_values(values, types, endianness, new_offset)]
  end

  defp build_header_fields(%__MODULE__{} = msg) do
    []
    |> maybe_add_field(msg.path, @field_path, "o")
    |> maybe_add_field(msg.interface, @field_interface, "s")
    |> maybe_add_field(msg.member, @field_member, "s")
    |> maybe_add_field(msg.error_name, @field_error_name, "s")
    |> maybe_add_field(msg.reply_serial, @field_reply_serial, "u")
    |> maybe_add_field(msg.destination, @field_destination, "s")
    |> maybe_add_field(msg.sender, @field_sender, "s")
    |> maybe_add_field(msg.signature, @field_signature, "g")
    |> maybe_add_field(msg.unix_fds, @field_unix_fds, "u")
    |> Enum.reverse()
  end

  defp maybe_add_field(acc, nil, _code, _sig), do: acc
  defp maybe_add_field(acc, value, code, sig), do: [{code, {sig, value}} | acc]

  # --- Private decode helpers ---

  defp decode_message_with_endianness(binary, endianness) do
    # Decode fixed header fields (after endianness byte)
    # type(1) + flags(1) + version(1) + body_len(4) + serial(4) = 11 bytes
    <<type_byte::8, flags::8, _version::8, rest::binary>> = binary

    with {:ok, msg_type} <- byte_to_type(type_byte),
         {:ok, body_length, rest2} <- decode_raw_uint32(rest, endianness),
         {:ok, serial, rest3} <- decode_raw_uint32(rest2, endianness) do
      # Now at offset 12 (1 endian + 3 fixed + 4 body_len + 4 serial)
      # Decode header fields array
      offset = 12

      case Decoder.decode_at(rest3, {:array, {:struct, [:byte, :variant]}}, endianness, offset) do
        {:ok, fields_list, rest4, offset} ->
          # Align to 8 bytes for body
          body_padding = rem(8 - rem(offset, 8), 8)

          case rest4 do
            <<_pad::binary-size(body_padding), body_rest::binary>> ->
              body_offset = offset + body_padding

              # Extract signature from header fields
              sig = extract_field_value(fields_list, @field_signature)

              # Decode body
              case decode_body(body_rest, sig, body_length, endianness, body_offset) do
                :insufficient_data ->
                  {:error, :insufficient_data}

                {body, rest5} ->
                  msg = %__MODULE__{
                    type: msg_type,
                    serial: serial,
                    flags: flags,
                    path: extract_field_value(fields_list, @field_path),
                    interface: extract_field_value(fields_list, @field_interface),
                    member: extract_field_value(fields_list, @field_member),
                    error_name: extract_field_value(fields_list, @field_error_name),
                    reply_serial: extract_field_value(fields_list, @field_reply_serial),
                    destination: extract_field_value(fields_list, @field_destination),
                    sender: extract_field_value(fields_list, @field_sender),
                    signature: sig,
                    unix_fds: extract_field_value(fields_list, @field_unix_fds),
                    body: body
                  }

                  {:ok, msg, rest5}
              end

            _ ->
              {:error, :insufficient_data_for_body_padding}
          end

        error ->
          error
      end
    end
  end

  defp decode_body(binary, nil, _body_length, _endianness, _offset), do: {[], binary}

  defp decode_body(binary, "", _body_length, _endianness, _offset), do: {[], binary}

  defp decode_body(binary, signature, body_length, endianness, _offset) do
    if byte_size(binary) < body_length do
      :insufficient_data
    else
      <<body_data::binary-size(body_length), rest::binary>> = binary
      {:ok, types} = Types.parse_types(signature)

      # Body alignment is relative to the body start (offset 0)
      case decode_body_values(body_data, types, endianness, 0) do
        {:ok, values, _rest, _offset} -> {values, rest}
        {:error, _reason} ->
          {[], rest}
      end
    end
  end

  defp decode_body_values(binary, [], _endianness, offset), do: {:ok, [], binary, offset}

  defp decode_body_values(binary, [type | types], endianness, offset) do
    case Decoder.decode_at(binary, type, endianness, offset) do
      {:ok, value, rest, new_offset} ->
        case decode_body_values(rest, types, endianness, new_offset) do
          {:ok, values, rest2, final_offset} ->
            {:ok, [value | values], rest2, final_offset}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp extract_field_value(fields_list, code) do
    case Enum.find(fields_list, fn {c, _v} -> c == code end) do
      {_, {_sig, value}} -> value
      nil -> nil
    end
  end

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

  defp endianness_to_byte(:little), do: ?l
  defp endianness_to_byte(:big), do: ?B

  defp type_to_byte(:method_call), do: @type_method_call
  defp type_to_byte(:method_return), do: @type_method_return
  defp type_to_byte(:error), do: @type_error
  defp type_to_byte(:signal), do: @type_signal

  defp byte_to_type(@type_method_call), do: {:ok, :method_call}
  defp byte_to_type(@type_method_return), do: {:ok, :method_return}
  defp byte_to_type(@type_error), do: {:ok, :error}
  defp byte_to_type(@type_signal), do: {:ok, :signal}
  defp byte_to_type(byte), do: {:error, {:invalid_message_type, byte}}

  defp encode_uint32(value, :little), do: <<value::unsigned-integer-size(32)-little>>
  defp encode_uint32(value, :big), do: <<value::unsigned-integer-size(32)-big>>
end
