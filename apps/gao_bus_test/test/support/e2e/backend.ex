defmodule GaoBusTest.E2E.Backend do
  @moduledoc """
  Behaviour for isolated E2E bus backends.
  """

  @callback start(keyword()) :: {:ok, term()} | {:error, term()}
  @callback address(term()) :: String.t()
  @callback probe(term()) :: :ok | {:error, term()}
  @callback diagnostics(term()) :: map()
  @callback stop(term()) :: :ok
end
