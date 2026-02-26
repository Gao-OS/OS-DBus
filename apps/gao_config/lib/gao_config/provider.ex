defmodule GaoConfig.Provider do
  @moduledoc """
  Behaviour for configuration providers.

  Providers plug into the config store to handle specific configuration
  sections (e.g., network, display, audio).
  """

  @doc "The section name this provider handles."
  @callback section() :: String.t()

  @doc "Validate a key/value pair for this section."
  @callback validate(key :: String.t(), value :: term()) ::
              :ok | {:error, String.t()}

  @doc "Called after a value is set in this section."
  @callback on_change(key :: String.t(), value :: term()) :: :ok

  @doc "Get default values for this section."
  @callback defaults() :: [{String.t(), term()}]

  @optional_callbacks [on_change: 2, defaults: 0]
end
