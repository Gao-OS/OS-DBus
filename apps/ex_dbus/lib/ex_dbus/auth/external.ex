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

  defstruct [:uid, :state, :guid]

  @impl true
  def init(opts \\ []) do
    uid = Keyword.get_lazy(opts, :uid, fn -> current_uid() end)
    %__MODULE__{uid: uid, state: :init}
  end

  @impl true
  def initial_command(%__MODULE__{uid: uid} = state) do
    uid_hex = uid |> Integer.to_string() |> hex_encode()
    {:send, "AUTH EXTERNAL #{uid_hex}", %{state | state: :waiting_ok}}
  end

  @impl true
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

  def handle_line(line, %__MODULE__{state: other}) do
    {:error, {:unexpected_state, other, line}}
  end

  defp hex_encode(string) do
    string
    |> :binary.bin_to_list()
    |> Enum.map_join(fn byte -> Integer.to_string(byte, 16) |> String.pad_leading(2, "0") end)
  end

  defp current_uid do
    case System.cmd("id", ["-u"]) do
      {uid_str, 0} -> uid_str |> String.trim() |> String.to_integer()
      _ -> 0
    end
  end
end
