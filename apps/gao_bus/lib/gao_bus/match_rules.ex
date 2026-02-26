defmodule GaoBus.MatchRules do
  @moduledoc """
  D-Bus match rules for signal subscription filtering.

  Stores match rules per peer and evaluates signals against them.
  Rules are parsed from the standard D-Bus match rule string format:

      type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'
  """

  use GenServer

  require Logger

  @table :gao_bus_match_rules

  defstruct [
    :type,
    :sender,
    :interface,
    :member,
    :path,
    :path_namespace,
    :destination,
    :eavesdrop,
    args: %{}
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a match rule for a peer.

  The rule_string follows D-Bus match rule format:
  `type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'`

  Returns `:ok` or `{:error, reason}`.
  """
  def add_match(peer_pid, rule_string) do
    case parse(rule_string) do
      {:ok, rule} ->
        GenServer.call(__MODULE__, {:add, peer_pid, rule, rule_string})

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Remove a match rule for a peer.
  """
  def remove_match(peer_pid, rule_string) do
    GenServer.call(__MODULE__, {:remove, peer_pid, rule_string})
  end

  @doc """
  Remove all match rules for a peer (called on disconnect).
  """
  def peer_disconnected(peer_pid) do
    GenServer.cast(__MODULE__, {:peer_disconnected, peer_pid})
  end

  @doc """
  Get all peer PIDs that have a match rule matching the given signal.

  Returns a list of `{pid, unique_name}` tuples.
  """
  def matching_peers(signal) do
    try do
      :ets.tab2list(@table)
      |> Enum.filter(fn {_pid, _name, rule, _raw} -> matches?(rule, signal) end)
      |> Enum.map(fn {pid, _name, _rule, _raw} -> pid end)
      |> Enum.uniq()
    catch
      :error, :badarg -> []
    end
  end

  @doc """
  Parse a D-Bus match rule string into a `%GaoBus.MatchRules{}` struct.
  """
  def parse(rule_string) when is_binary(rule_string) do
    pairs = split_rule(rule_string)

    rule =
      Enum.reduce_while(pairs, %__MODULE__{}, fn {key, value}, acc ->
        case apply_pair(acc, key, value) do
          {:ok, acc} -> {:cont, acc}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case rule do
      {:error, _} = err -> err
      %__MODULE__{} = r -> {:ok, r}
    end
  end

  @doc """
  Check if a signal message matches a rule.
  """
  def matches?(%__MODULE__{} = rule, %ExDBus.Message{} = msg) do
    match_field(rule.type, msg.type) and
      match_field(rule.sender, msg.sender) and
      match_field(rule.interface, msg.interface) and
      match_field(rule.member, msg.member) and
      match_path(rule.path, rule.path_namespace, msg.path) and
      match_field(rule.destination, msg.destination) and
      match_args(rule.args, msg.body)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:bag, :named_table, :protected])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:add, peer_pid, rule, raw}, _from, state) do
    :ets.insert(@table, {peer_pid, nil, rule, raw})
    {:reply, :ok, state}
  end

  def handle_call({:remove, peer_pid, raw}, _from, state) do
    # Delete the first matching rule for this peer
    matches = :ets.match_object(@table, {peer_pid, :_, :_, raw})

    case matches do
      [entry | _] ->
        :ets.delete_object(@table, entry)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, "org.freedesktop.DBus.Error.MatchRuleNotFound"}, state}
    end
  end

  @impl true
  def handle_cast({:peer_disconnected, peer_pid}, state) do
    :ets.match_delete(@table, {peer_pid, :_, :_, :_})
    {:noreply, state}
  end

  # --- Rule parsing ---

  defp split_rule(""), do: []

  defp split_rule(rule_string) do
    # Split on commas, but respect quoted values
    rule_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          # Strip surrounding quotes from value
          value = value |> String.trim_leading("'") |> String.trim_trailing("'")
          {String.trim(key), value}

        [key] ->
          {String.trim(key), ""}
      end
    end)
  end

  defp apply_pair(rule, "type", value) do
    case value do
      "signal" -> {:ok, %{rule | type: :signal}}
      "method_call" -> {:ok, %{rule | type: :method_call}}
      "method_return" -> {:ok, %{rule | type: :method_return}}
      "error" -> {:ok, %{rule | type: :error}}
      _ -> {:error, {:invalid_type, value}}
    end
  end

  defp apply_pair(rule, "sender", value), do: {:ok, %{rule | sender: value}}
  defp apply_pair(rule, "interface", value), do: {:ok, %{rule | interface: value}}
  defp apply_pair(rule, "member", value), do: {:ok, %{rule | member: value}}
  defp apply_pair(rule, "path", value), do: {:ok, %{rule | path: value}}
  defp apply_pair(rule, "path_namespace", value), do: {:ok, %{rule | path_namespace: value}}
  defp apply_pair(rule, "destination", value), do: {:ok, %{rule | destination: value}}

  defp apply_pair(rule, "eavesdrop", value) do
    {:ok, %{rule | eavesdrop: value == "true"}}
  end

  defp apply_pair(rule, "arg" <> rest, value) do
    case Integer.parse(rest) do
      {n, ""} when n >= 0 and n <= 63 ->
        {:ok, %{rule | args: Map.put(rule.args, {:arg, n}, value)}}

      {n, "path"} when n >= 0 and n <= 63 ->
        {:ok, %{rule | args: Map.put(rule.args, {:arg_path, n}, value)}}

      _ ->
        {:error, {:invalid_arg, "arg" <> rest}}
    end
  end

  defp apply_pair(_rule, key, _value), do: {:error, {:unknown_key, key}}

  # --- Matching ---

  defp match_field(nil, _), do: true
  defp match_field(expected, actual), do: expected == actual

  defp match_path(nil, nil, _), do: true
  defp match_path(path, nil, msg_path), do: path == msg_path

  defp match_path(nil, namespace, msg_path) when is_binary(msg_path) do
    msg_path == namespace or String.starts_with?(msg_path, namespace <> "/")
  end

  defp match_path(nil, _namespace, nil), do: false
  defp match_path(_, _, _), do: false

  defp match_args(args, _body) when map_size(args) == 0, do: true
  defp match_args(_args, nil), do: false
  defp match_args(_args, []), do: false

  defp match_args(args, body) when is_list(body) do
    Enum.all?(args, fn
      {{:arg, n}, expected} ->
        case Enum.at(body, n) do
          ^expected -> true
          _ -> false
        end

      {{:arg_path, n}, expected} ->
        case Enum.at(body, n) do
          nil ->
            false

          actual ->
            actual == expected or
              String.starts_with?(actual, expected <> "/")
        end
    end)
  end
end
