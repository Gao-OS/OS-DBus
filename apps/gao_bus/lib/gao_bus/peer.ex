defmodule GaoBus.Peer do
  @moduledoc """
  GenServer for a single connected D-Bus client.

  Lifecycle:
  1. Accept socket from Listener
  2. Run D-Bus auth handshake
  3. Switch to binary protocol
  4. Decode incoming messages → forward to Router
  5. Receive messages from Router → encode → send to socket

  Each peer is auto-assigned a unique connection name (:1.N) during Hello().
  """

  use GenServer

  alias ExDBus.Message

  require Logger

  @auth_guid Application.compile_env(:gao_bus, :auth_guid, "gaobusauthguid00000000000000000")

  defstruct [
    :socket,
    :unique_name,
    :credentials,
    state: :waiting_socket,
    buffer: <<>>,
    auth_buffer: <<>>
  ]

  # Global atomic counter for unique names
  @counter_key :gao_bus_peer_counter

  def ensure_counter do
    unless :persistent_term.get(@counter_key, nil) do
      ref = :atomics.new(1, signed: false)
      :persistent_term.put(@counter_key, ref)
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Get this peer's unique name. Returns nil if Hello() hasn't been called.
  """
  def get_unique_name(pid) do
    GenServer.call(pid, :get_unique_name)
  end

  @doc """
  Get this peer's credentials. Returns nil if not authenticated.
  """
  def get_credentials(pid) do
    GenServer.call(pid, :get_credentials)
  end

  @doc """
  Assign a unique name to this peer. Called during Hello().
  """
  def assign_unique_name(pid) do
    GenServer.call(pid, :assign_unique_name)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    socket = Keyword.fetch!(opts, :socket)
    {:ok, %__MODULE__{socket: socket}}
  end

  @impl true
  def handle_info(:socket_ready, %{state: :waiting_socket} = state) do
    # Socket ownership transferred — begin auth
    :inet.setopts(state.socket, active: :once)
    {:noreply, %{state | state: :authenticating}}
  end

  # --- Auth phase: line-based protocol ---

  def handle_info({:tcp, _socket, data}, %{state: :authenticating} = state) do
    handle_auth_data(data, state)
  end

  # --- Connected phase: binary D-Bus protocol ---

  def handle_info({:tcp, _socket, data}, %{state: :connected} = state) do
    buffer = state.buffer <> data
    {state, buffer} = process_messages(state, buffer)
    :inet.setopts(state.socket, active: :once)
    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.debug("GaoBus.Peer: socket closed for #{state.unique_name || "unauthenticated"}")
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("GaoBus.Peer: socket error for #{state.unique_name}: #{inspect(reason)}")
    cleanup(state)
    {:stop, reason, state}
  end

  # Messages from Router to send to the client
  def handle_info({:send_message, msg}, %{state: :connected} = state) do
    data = Message.encode_message(msg)
    :gen_tcp.send(state.socket, data)
    {:noreply, state}
  end

  def handle_info({:send_message, _msg}, state) do
    # Not connected yet, drop
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_unique_name, _from, state) do
    {:reply, state.unique_name, state}
  end

  def handle_call(:get_credentials, _from, state) do
    {:reply, state.credentials, state}
  end

  def handle_call(:assign_unique_name, _from, state) do
    if state.unique_name do
      {:reply, state.unique_name, state}
    else
      n = next_peer_id()
      name = ":1.#{n}"
      GaoBus.PubSub.broadcast({:peer_connected, name, self()})

      # Set up default capabilities based on credentials
      creds = Map.put(state.credentials || %{}, :unique_name, name)
      if Process.whereis(GaoBus.Policy.Capability) do
        GaoBus.Policy.Capability.setup_defaults(name, creds)
      end

      {:reply, name, %{state | unique_name: name, credentials: creds}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  # --- Auth handling ---

  defp handle_auth_data(data, state) do
    buffer = state.auth_buffer <> data

    # First byte must be null byte
    buffer =
      case buffer do
        <<0, rest::binary>> -> rest
        _ -> buffer
      end

    case extract_line(buffer) do
      {line, rest} ->
        handle_auth_line(line, %{state | auth_buffer: rest})

      nil ->
        :inet.setopts(state.socket, active: :once)
        {:noreply, %{state | auth_buffer: buffer}}
    end
  end

  defp handle_auth_line("AUTH " <> rest, state) do
    # Extract credentials from auth mechanism
    state = extract_credentials(rest, state)
    # Accept any auth mechanism for now — respond with OK
    :gen_tcp.send(state.socket, "OK #{@auth_guid}\r\n")
    wait_for_begin(state)
  end

  defp handle_auth_line("BEGIN", state) do
    # Client sent BEGIN — switch to binary protocol
    Logger.debug("GaoBus.Peer: auth complete, entering binary mode")
    :inet.setopts(state.socket, active: :once)
    {:noreply, %{state | state: :connected, buffer: state.auth_buffer}}
  end

  defp handle_auth_line("NEGOTIATE_UNIX_FD", state) do
    # We don't support FD passing yet
    :gen_tcp.send(state.socket, "ERROR\r\n")
    wait_for_begin(state)
  end

  defp handle_auth_line(line, state) do
    Logger.debug("GaoBus.Peer: unknown auth line: #{inspect(line)}")
    :gen_tcp.send(state.socket, "ERROR\r\n")
    wait_for_begin(state)
  end

  defp wait_for_begin(state) do
    # Check if BEGIN is already in the buffer
    case extract_line(state.auth_buffer) do
      {"BEGIN", rest} ->
        Logger.debug("GaoBus.Peer: auth complete, entering binary mode")
        :inet.setopts(state.socket, active: :once)
        {:noreply, %{state | state: :connected, buffer: rest}}

      {line, rest} ->
        # Another auth line before BEGIN
        handle_auth_line(line, %{state | auth_buffer: rest})

      nil ->
        :inet.setopts(state.socket, active: :once)
        {:noreply, state}
    end
  end

  # --- Message processing ---

  defp process_messages(state, buffer) when byte_size(buffer) < 16, do: {state, buffer}

  defp process_messages(state, buffer) do
    case Message.decode_message(buffer) do
      {:ok, msg, rest} ->
        # Stamp sender
        msg = %{msg | sender: state.unique_name}
        GaoBus.Router.route(msg, self())
        process_messages(state, rest)

      {:error, :insufficient_data} ->
        {state, buffer}

      {:error, reason} ->
        Logger.error("GaoBus.Peer: decode error: #{inspect(reason)}")
        {state, buffer}
    end
  end

  # --- Helpers ---

  defp extract_credentials(auth_line, state) do
    parts = String.split(auth_line, " ", trim: true)

    credentials =
      case parts do
        ["EXTERNAL", uid_hex] ->
          case decode_hex_uid(uid_hex) do
            {:ok, uid} -> %{uid: uid}
            _ -> %{}
          end

        ["ANONYMOUS" | _] ->
          %{uid: nil}

        _ ->
          %{}
      end

    # Try to get peer credentials from socket
    credentials =
      case :inet.peername(state.socket) do
        {:ok, {:local, _}} ->
          # Unix socket — try to get peer credentials via SO_PEERCRED
          credentials

        _ ->
          credentials
      end

    %{state | credentials: credentials}
  end

  defp decode_hex_uid(hex_string) do
    try do
      uid_string = Base.decode16!(hex_string, case: :mixed)
      case Integer.parse(uid_string) do
        {uid, ""} -> {:ok, uid}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

  defp cleanup(state) do
    if state.unique_name do
      GaoBus.PubSub.broadcast({:peer_disconnected, state.unique_name, self()})
      GaoBus.NameRegistry.peer_disconnected(self())
      GaoBus.MatchRules.peer_disconnected(self())

      if Process.whereis(GaoBus.Policy.Capability) do
        GaoBus.Policy.Capability.peer_disconnected(state.unique_name)
      end

      GaoBus.Router.unregister_peer(self())
    end

    :gen_tcp.close(state.socket)
  rescue
    _ -> :ok
  end

  defp extract_line(buffer) do
    case :binary.match(buffer, "\r\n") do
      {pos, 2} ->
        line = binary_part(buffer, 0, pos)
        rest = binary_part(buffer, pos + 2, byte_size(buffer) - pos - 2)
        {line, rest}

      :nomatch ->
        nil
    end
  end

  defp next_peer_id do
    ensure_counter()
    ref = :persistent_term.get(@counter_key)
    :atomics.add_get(ref, 1, 1)
  end
end
