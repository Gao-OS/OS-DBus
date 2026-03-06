defmodule ExDBus.Auth.External do
  @moduledoc """
  EXTERNAL authentication mechanism for D-Bus.

  Uses the Unix uid of the connecting process, encoded as hex.
  This is the primary auth mechanism for local D-Bus connections.

  ## State machine

      :init → send AUTH EXTERNAL <uid_hex> → :waiting_ok
      :waiting_ok → receive OK <guid> → :authenticated
      :waiting_ok → receive REJECTED → :error
  """

  @behaviour ExDBus.Auth.Mechanism

  @type t :: %__MODULE__{
          uid: non_neg_integer() | nil,
          state: :init | :waiting_ok | :authenticated,
          guid: String.t() | nil
        }

  defstruct [:uid, :state, :guid]

  @impl true
  @spec init(keyword()) :: t()
  def init(opts \\ []) do
    uid = Keyword.get_lazy(opts, :uid, fn -> current_uid() end)
    %__MODULE__{uid: uid, state: :init}
  end

  @impl true
  @spec initial_command(t()) :: {:send, String.t(), t()}
  def initial_command(%__MODULE__{uid: uid} = state) do
    uid_hex = uid |> Integer.to_string() |> hex_encode()
    {:send, "AUTH EXTERNAL #{uid_hex}", %{state | state: :waiting_ok}}
  end

  @impl true
  @spec handle_line(String.t(), t()) :: {:ok, String.t(), t()} | {:error, term()}
  def handle_line(line, %__MODULE__{state: :waiting_ok} = state) do
    case String.split(line, " ", parts: 2) do
      ["OK", guid] ->
        {:ok, String.trim(guid), %{state | state: :authenticated, guid: String.trim(guid)}}

      ["REJECTED" | _] ->
        {:error, :rejected}

      ["ERROR" | _] ->
        {:error, {:auth_error, line}}

      _ ->
        {:error, {:unexpected_response, line}}
    end
  end

  @impl true
  @spec handle_line(String.t(), t()) :: {:ok, String.t(), t()} | {:error, term()}
  def handle_line(line, %__MODULE__{state: other}) do
    {:error, {:unexpected_state, other, line}}
  end

  defp hex_encode(string) do
    string
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte -> Integer.to_string(byte, 16) |> String.pad_leading(2, "0") end)
  end

  defp current_uid do
    case :os.type() do
      {:unix, _} ->
        # Read UID from /proc on Linux, fall back to `id -u` on other Unix
        case File.read("/proc/self/status") do
          {:ok, status} -> parse_uid_from_proc(status)
          _ -> uid_from_command()
        end

      _ ->
        0
    end
  end

  defp parse_uid_from_proc(status) do
    case Regex.run(~r/^Uid:\s+(\d+)/m, status) do
      [_, uid_str] -> String.to_integer(uid_str)
      _ -> uid_from_command()
    end
  end

  defp uid_from_command do
    case System.cmd("id", ["-u"]) do
      {uid_str, 0} -> uid_str |> String.trim() |> String.to_integer()
      _ -> 0
    end
  end
end
