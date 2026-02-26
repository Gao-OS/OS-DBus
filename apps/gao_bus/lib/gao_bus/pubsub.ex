defmodule GaoBus.PubSub do
  @moduledoc """
  PubSub integration for broadcasting bus events.

  Used by gao_bus_web LiveViews to receive real-time updates.
  Silently no-ops if the PubSub server isn't running.
  """

  @topic "gao_bus:events"

  def topic, do: @topic

  def subscribe do
    case pubsub_name() do
      nil -> :ok
      name -> Phoenix.PubSub.subscribe(name, @topic)
    end
  end

  def broadcast(event) do
    case pubsub_name() do
      nil -> :ok
      name ->
        try do
          Phoenix.PubSub.broadcast(name, @topic, event)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp pubsub_name do
    name = Application.get_env(:gao_bus, :pubsub_name, GaoBusWeb.PubSub)

    if Process.whereis(name) do
      name
    else
      nil
    end
  end
end
