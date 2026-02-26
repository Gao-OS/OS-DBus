defmodule GaoConfig do
  @moduledoc """
  org.gaoos.Config1 system configuration service.

  Manages system configuration with a section/key/value model,
  backed by ETS for runtime and disk persistence.
  """

  defdelegate get(section, key), to: GaoConfig.ConfigStore
  defdelegate set(section, key, value), to: GaoConfig.ConfigStore
  defdelegate delete(section, key), to: GaoConfig.ConfigStore
  defdelegate list(section), to: GaoConfig.ConfigStore
  defdelegate list_sections(), to: GaoConfig.ConfigStore
end
