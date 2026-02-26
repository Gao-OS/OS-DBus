defmodule GaoConfig.DBusInterface do
  @moduledoc """
  D-Bus interface implementation for org.gaoos.Config1.

  Handles incoming method calls and translates them to ConfigStore operations.

  ## Methods

  - `Get(section: s, key: s) → value: s`
  - `Set(section: s, key: s, value: s)`
  - `Delete(section: s, key: s)`
  - `List(section: s) → entries: a{ss}`
  - `ListSections() → sections: as`
  - `GetVersion() → version: s`

  ## Signals

  - `ConfigChanged(section: s, key: s, value: s)`
  """

  alias ExDBus.Message

  @interface "org.gaoos.Config1"
  @version "0.1.0"

  @doc """
  Handle a D-Bus method call to the Config1 interface.

  Returns `{:ok, reply_message}` or `{:error, error_message}`.
  """
  def handle_method(%Message{interface: @interface, member: member} = msg) do
    case member do
      "Get" -> handle_get(msg)
      "Set" -> handle_set(msg)
      "Delete" -> handle_delete(msg)
      "List" -> handle_list(msg)
      "ListSections" -> handle_list_sections(msg)
      "GetVersion" -> handle_get_version(msg)
      _ -> {:error, make_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method: #{member}")}
    end
  end

  def handle_method(%Message{} = msg) do
    {:error, make_error(msg, "org.freedesktop.DBus.Error.UnknownInterface", "Unknown interface")}
  end

  defp handle_get(msg) do
    [section, key] = msg.body

    case GaoConfig.ConfigStore.get(section, key) do
      {:ok, value} ->
        reply = Message.method_return(msg.serial,
          destination: msg.sender,
          signature: "s",
          body: [to_string(value)]
        )
        {:ok, reply}

      {:error, :not_found} ->
        {:error, make_error(msg, "org.gaoos.Config1.Error.NotFound",
          "Key '#{key}' not found in section '#{section}'")}
    end
  end

  defp handle_set(msg) do
    [section, key, value] = msg.body
    :ok = GaoConfig.ConfigStore.set(section, key, value)

    reply = Message.method_return(msg.serial, destination: msg.sender)
    {:ok, reply}
  end

  defp handle_delete(msg) do
    [section, key] = msg.body
    :ok = GaoConfig.ConfigStore.delete(section, key)

    reply = Message.method_return(msg.serial, destination: msg.sender)
    {:ok, reply}
  end

  defp handle_list(msg) do
    [section] = msg.body
    entries = GaoConfig.ConfigStore.list(section)

    # Return as array of dict entries {key: string, value: string}
    pairs = Enum.map(entries, fn {k, v} -> {to_string(k), to_string(v)} end)

    reply = Message.method_return(msg.serial,
      destination: msg.sender,
      signature: "a{ss}",
      body: [pairs]
    )
    {:ok, reply}
  end

  defp handle_list_sections(msg) do
    sections = GaoConfig.ConfigStore.list_sections()

    reply = Message.method_return(msg.serial,
      destination: msg.sender,
      signature: "as",
      body: [sections]
    )
    {:ok, reply}
  end

  defp handle_get_version(msg) do
    reply = Message.method_return(msg.serial,
      destination: msg.sender,
      signature: "s",
      body: [@version]
    )
    {:ok, reply}
  end

  defp make_error(msg, error_name, error_msg) do
    Message.error(error_name, msg.serial,
      destination: msg.sender,
      signature: "s",
      body: [error_msg]
    )
  end
end
