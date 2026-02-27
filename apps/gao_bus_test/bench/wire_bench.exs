alias ExDBus.Wire.{Encoder, Decoder, Types}
alias ExDBus.Message

# --- Data setup ---

simple_string = "Hello, D-Bus!"
long_string = String.duplicate("x", 4096)
int_list = Enum.to_list(1..100)
nested_struct = {"hello", 42, true, {1.5, "nested"}}

# Pre-encode for decode benchmarks
string_bin = Encoder.encode(simple_string, :string) |> IO.iodata_to_binary()
int_list_bin = Encoder.encode(int_list, {:array, :int32}) |> IO.iodata_to_binary()

# Build a realistic method_call message
method_call =
  Message.method_call("/org/example/Object", "org.example.Interface", "DoStuff",
    serial: 1,
    destination: "org.example.Service",
    signature: "s",
    body: ["hello world"]
  )

encoded_msg = Message.encode_message(method_call, :little)
encoded_msg_bin = IO.iodata_to_binary(encoded_msg)

# A{sv} dict — the most common D-Bus pattern
asv_value = [
  {"Name", {"s", "GaoOS"}},
  {"Version", {"s", "0.1.0"}},
  {"Debug", {"b", true}},
  {"Port", {"u", 8080}}
]

Benchee.run(
  %{
    "encode string" => fn -> Encoder.encode(simple_string, :string) end,
    "encode long string (4KB)" => fn -> Encoder.encode(long_string, :string) end,
    "encode int32 array (100)" => fn -> Encoder.encode(int_list, {:array, :int32}) end,
    "encode a{sv} dict" => fn -> Encoder.encode(asv_value, {:array, {:dict_entry, :string, :variant}}) end,
    "encode struct" => fn -> Encoder.encode(nested_struct, {:struct, [:string, :int32, :boolean, {:struct, [:double, :string]}]}) end,
    "decode string" => fn -> Decoder.decode(string_bin, :string) end,
    "decode int32 array (100)" => fn -> Decoder.decode(int_list_bin, {:array, :int32}) end,
    "parse signature 'a{sv}'" => fn -> Types.parse_signature("a{sv}") end,
    "parse signature '(sibd(ds))'" => fn -> Types.parse_signature("(sibd(ds))") end,
    "encode message (method_call)" => fn -> Message.encode_message(method_call, :little) end,
    "decode message (method_call)" => fn -> Message.decode_message(encoded_msg_bin) end,
    "roundtrip message" => fn ->
      encoded = Message.encode_message(method_call, :little)
      bin = IO.iodata_to_binary(encoded)
      Message.decode_message(bin)
    end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)
