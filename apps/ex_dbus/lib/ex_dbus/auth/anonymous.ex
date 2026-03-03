defmodule ExDBus.Auth.Anonymous do
  @moduledoc """
  ANONYMOUS authentication mechanism for D-Bus.

  Used for testing and environments where no authentication is needed.
  """

  @behaviour ExDBus.Auth.Mechanism

  @type t :: %__MODULE__{
          state: :init | :waiting_ok | :authenticated,
          guid: String.t() | nil
        }

  defstruct [:state, :guid]

  @impl true
  @spec init(keyword()) :: t()
  def init(_opts \\ []) do
    %__MODULE__{state: :init}
  end

  @impl true
  @spec initial_command(t()) :: {:send, String.t(), t()}
  def initial_command(%__MODULE__{} = state) do
    {:send, "AUTH ANONYMOUS", %{state | state: :waiting_ok}}
  end

  @impl true
  @spec handle_line(String.t(), t()) :: {:ok, String.t(), t()} | {:error, term()}
  def handle_line(line, %__MODULE__{state: :waiting_ok} = state) do
    case String.split(line, " ", parts: 2) do
      ["OK", guid] ->
        {:ok, String.trim(guid), %{state | state: :authenticated, guid: String.trim(guid)}}

      ["REJECTED" | _] ->
        {:error, :rejected}

      _ ->
        {:error, {:unexpected_response, line}}
    end
  end

  @spec handle_line(String.t(), t()) :: {:ok, String.t(), t()} | {:error, term()}
  def handle_line(line, %__MODULE__{state: other}) do
    {:error, {:unexpected_state, other, line}}
  end
end
