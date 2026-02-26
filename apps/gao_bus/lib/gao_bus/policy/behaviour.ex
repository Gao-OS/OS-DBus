defmodule GaoBus.Policy.Behaviour do
  @moduledoc """
  Behaviour for D-Bus policy engines.

  Policy modules decide whether a message should be allowed or denied
  based on sender credentials and message attributes.
  """

  @type credentials :: %{
          uid: non_neg_integer() | nil,
          gid: non_neg_integer() | nil,
          pid: non_neg_integer() | nil,
          unique_name: String.t() | nil
        }

  @type message_info :: %{
          type: :method_call | :method_return | :error | :signal,
          sender: String.t() | nil,
          destination: String.t() | nil,
          interface: String.t() | nil,
          member: String.t() | nil,
          path: String.t() | nil
        }

  @type decision :: :allow | {:deny, String.t()}

  @doc """
  Check if a message should be allowed.
  """
  @callback check_send(credentials(), message_info()) :: decision()

  @doc """
  Check if a peer can own a well-known name.
  """
  @callback check_own(credentials(), name :: String.t()) :: decision()

  @doc """
  Check if a peer is allowed to eavesdrop on messages.
  """
  @callback check_eavesdrop(credentials()) :: decision()
end
