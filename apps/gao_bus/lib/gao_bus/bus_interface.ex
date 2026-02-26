defmodule GaoBus.BusInterface do
  @moduledoc """
  Implementation of the org.freedesktop.DBus interface.

  The bus itself responds to these standard methods:
  - Hello() → assign unique name
  - RequestName(name, flags) → register well-known name
  - ReleaseName(name) → release
  - GetNameOwner(name) → lookup
  - ListNames() → all registered names
  - ListActivatableNames() → activatable names (empty for now)
  - NameHasOwner(name) → boolean check
  - AddMatch(rule) → subscribe to signals
  - RemoveMatch(rule) → unsubscribe
  - GetId() → bus instance ID
  - Introspect() → introspection XML (on org.freedesktop.DBus.Introspectable)
  """

  alias ExDBus.Message

  @bus_name "org.freedesktop.DBus"

  @doc """
  Handle a message addressed to org.freedesktop.DBus.

  Returns `{reply_message | nil, updated_router_state}`.
  """
  def handle_message(%Message{type: :method_call} = msg, from_peer_pid, state) do
    case {msg.interface, msg.member} do
      {"org.freedesktop.DBus.Introspectable", "Introspect"} ->
        handle_introspect(msg, from_peer_pid, state)

      {"org.freedesktop.DBus.Properties", "Get"} ->
        handle_properties_get(msg, from_peer_pid, state)

      {"org.freedesktop.DBus.Properties", "GetAll"} ->
        handle_properties_get_all(msg, from_peer_pid, state)

      {_, "Hello"} -> handle_hello(msg, from_peer_pid, state)
      {_, "RequestName"} -> handle_request_name(msg, from_peer_pid, state)
      {_, "ReleaseName"} -> handle_release_name(msg, from_peer_pid, state)
      {_, "GetNameOwner"} -> handle_get_name_owner(msg, from_peer_pid, state)
      {_, "ListNames"} -> handle_list_names(msg, from_peer_pid, state)
      {_, "ListActivatableNames"} -> handle_list_activatable_names(msg, from_peer_pid, state)
      {_, "NameHasOwner"} -> handle_name_has_owner(msg, from_peer_pid, state)
      {_, "AddMatch"} -> handle_add_match(msg, from_peer_pid, state)
      {_, "RemoveMatch"} -> handle_remove_match(msg, from_peer_pid, state)
      {_, "GetId"} -> handle_get_id(msg, from_peer_pid, state)
      _ -> {make_error(msg, "org.freedesktop.DBus.Error.UnknownMethod",
              "Unknown method: #{msg.member}", state), state}
    end
  end

  def handle_message(_msg, _from_peer_pid, state) do
    {nil, state}
  end

  # --- Method handlers ---

  defp handle_hello(msg, from_peer_pid, state) do
    # Assign a unique connection name
    unique_name = GaoBus.Peer.get_unique_name(from_peer_pid)

    case unique_name do
      nil ->
        # First Hello — assign name
        name = GaoBus.Peer.assign_unique_name(from_peer_pid)
        GaoBus.NameRegistry.register_unique(name, from_peer_pid)
        GaoBus.Router.register_peer(from_peer_pid, name)

        {reply, state} = make_reply(msg, "s", [name], state)
        {reply, state}

      _ ->
        # Already has a name — error per spec
        {make_error(msg, "org.freedesktop.DBus.Error.Failed",
          "Already called Hello", state), state}
    end
  end

  defp handle_request_name(msg, from_peer_pid, state) do
    [name, flags] = msg.body
    unique_name = GaoBus.Peer.get_unique_name(from_peer_pid)

    {:ok, result} = GaoBus.NameRegistry.request_name(name, flags, from_peer_pid, unique_name)

    {reply, state} = make_reply(msg, "u", [result], state)
    {reply, state}
  end

  defp handle_release_name(msg, from_peer_pid, state) do
    [name] = msg.body

    {:ok, result} = GaoBus.NameRegistry.release_name(name, from_peer_pid)

    {reply, state} = make_reply(msg, "u", [result], state)
    {reply, state}
  end

  defp handle_get_name_owner(msg, _from_peer_pid, state) do
    [name] = msg.body

    case GaoBus.NameRegistry.get_name_owner(name) do
      {:ok, owner} ->
        {reply, state} = make_reply(msg, "s", [owner], state)
        {reply, state}

      {:error, error_name} ->
        {make_error(msg, error_name,
          "The name #{name} was not provided by any .service files", state), state}
    end
  end

  defp handle_list_names(msg, _from_peer_pid, state) do
    names = GaoBus.NameRegistry.list_names()
    {reply, state} = make_reply(msg, "as", [names], state)
    {reply, state}
  end

  defp handle_name_has_owner(msg, _from_peer_pid, state) do
    [name] = msg.body
    has_owner = GaoBus.NameRegistry.name_has_owner?(name)
    {reply, state} = make_reply(msg, "b", [has_owner], state)
    {reply, state}
  end

  defp handle_get_id(msg, _from_peer_pid, state) do
    id = Application.get_env(:gao_bus, :bus_id, "gaobusid000000000000000000000000")
    {reply, state} = make_reply(msg, "s", [id], state)
    {reply, state}
  end

  defp handle_list_activatable_names(msg, _from_peer_pid, state) do
    # No activation support yet — return empty list
    {reply, state} = make_reply(msg, "as", [[]], state)
    {reply, state}
  end

  defp handle_add_match(msg, from_peer_pid, state) do
    [rule_string] = msg.body

    case GaoBus.MatchRules.add_match(from_peer_pid, rule_string) do
      :ok ->
        {reply, state} = make_reply(msg, nil, [], state)
        {reply, state}

      {:error, reason} ->
        {make_error(msg, "org.freedesktop.DBus.Error.MatchRuleInvalid",
          "Invalid match rule: #{inspect(reason)}", state), state}
    end
  end

  defp handle_remove_match(msg, from_peer_pid, state) do
    [rule_string] = msg.body

    case GaoBus.MatchRules.remove_match(from_peer_pid, rule_string) do
      :ok ->
        {reply, state} = make_reply(msg, nil, [], state)
        {reply, state}

      {:error, error_name} ->
        {make_error(msg, error_name,
          "Match rule not found", state), state}
    end
  end

  defp handle_introspect(msg, _from_peer_pid, state) do
    xml = ExDBus.Introspection.to_xml(
      "/org/freedesktop/DBus",
      [
        ExDBus.Introspection.bus_interface(),
        ExDBus.Introspection.introspectable_interface(),
        ExDBus.Introspection.properties_interface(),
        ExDBus.Introspection.peer_interface()
      ]
    )

    {reply, state} = make_reply(msg, "s", [xml], state)
    {reply, state}
  end

  defp handle_properties_get(msg, _from_peer_pid, state) do
    [_interface_name, property_name] = msg.body

    case property_name do
      "Features" ->
        {reply, state} = make_reply(msg, "v", [{"as", []}], state)
        {reply, state}

      "Interfaces" ->
        interfaces = ["org.freedesktop.DBus", "org.freedesktop.DBus.Introspectable",
                       "org.freedesktop.DBus.Properties", "org.freedesktop.DBus.Peer"]
        {reply, state} = make_reply(msg, "v", [{"as", interfaces}], state)
        {reply, state}

      _ ->
        {make_error(msg, "org.freedesktop.DBus.Error.UnknownProperty",
          "Unknown property: #{property_name}", state), state}
    end
  end

  defp handle_properties_get_all(msg, _from_peer_pid, state) do
    props = [
      {"Features", {"as", []}},
      {"Interfaces", {"as", ["org.freedesktop.DBus", "org.freedesktop.DBus.Introspectable",
                              "org.freedesktop.DBus.Properties", "org.freedesktop.DBus.Peer"]}}
    ]

    {reply, state} = make_reply(msg, "a{sv}", [props], state)
    {reply, state}
  end

  # --- Reply helpers ---

  defp make_reply(msg, signature, body, state) do
    {serial, state} = next_serial(state)

    reply =
      Message.method_return(msg.serial,
        serial: serial,
        destination: msg.sender,
        sender: @bus_name,
        signature: signature,
        body: body
      )

    {reply, state}
  end

  defp make_error(msg, error_name, error_msg, state) do
    {serial, _state} = next_serial(state)

    Message.error(error_name, msg.serial,
      serial: serial,
      destination: msg.sender,
      sender: @bus_name,
      signature: "s",
      body: [error_msg]
    )
  end

  defp next_serial(state) do
    {state.next_serial, %{state | next_serial: state.next_serial + 1}}
  end
end
