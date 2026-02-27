defmodule GaoBus.Peer do
  @moduledoc """
  GenServer for a single connected D-Bus client.

  Lifecycle:
  1. Accept socket from Listener (`:socket` module handle)
  2. Run D-Bus auth handshake
  3. Switch to binary protocol
  4. Decode incoming messages → forward to Router
  5. Receive messages from Router → encode → send to socket

  Each peer is auto-assigned a unique connection name (:1.N) during Hello().

  Uses the Erlang `:socket` module for I/O to support Unix FD passing
  via SCM_RIGHTS (sendmsg/recvmsg with ancillary data).
  """

  use GenServer

  alias ExDBus.Message

  require Logger

  @auth_guid Application.compile_env(:gao_bus, :auth_guid, "gaobusauthguid00000000000000000")

  # Control buffer size for recvmsg — enough for a few FDs
  # Each FD is 4 bytes, plus cmsg header (~16 bytes)
  @ctrl_buf_size 256

  defstruct [
    :socket,
    :unique_name,
    :credentials,
    state: :waiting_socket,
    buffer: <<>>,
    auth_buffer: <<>>,
    fd_passing: false
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
    request_recv(state.socket)
    {:noreply, %{state | state: :authenticating}}
  end

  # --- Socket data arrival (`:socket` select notification) ---

  def handle_info({:"$socket", socket, :select, _info}, %{state: :authenticating} = state)
      when socket == state.socket do
    case do_recv(state.socket) do
      {:ok, data, _fds} ->
        handle_auth_data(data, state)

      {:error, :closed} ->
        Logger.debug("GaoBus.Peer: socket closed during auth")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("GaoBus.Peer: socket error during auth: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  def handle_info({:"$socket", socket, :select, _info}, %{state: :connected} = state)
      when socket == state.socket do
    case do_recv(state.socket) do
      {:ok, data, fds} ->
        buffer = state.buffer <> data
        {state, buffer} = process_messages(state, buffer, fds)
        request_recv(state.socket)
        {:noreply, %{state | buffer: buffer}}

      {:error, :closed} ->
        Logger.debug("GaoBus.Peer: socket closed for #{state.unique_name || "unauthenticated"}")
        cleanup(state)
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("GaoBus.Peer: socket error for #{state.unique_name}: #{inspect(reason)}")
        cleanup(state)
        {:stop, reason, state}
    end
  end

  # Messages from Router to send to the client
  def handle_info({:send_message, msg}, %{state: :connected} = state) do
    data = Message.encode_message(msg)

    if state.fd_passing and msg.fds != [] do
      do_send_with_fds(state.socket, data, msg.fds)
    else
      do_send(state.socket, data)
    end

    {:noreply, state}
  end

  def handle_info({:send_message, _msg}, state) do
    # Not connected yet, drop
    {:noreply, state}
  end

  def handle_info({:immediate_data, data, fds}, state) do
    handle_immediate_data(data, fds, state)
  end

  def handle_info({:socket_error, :closed}, state) do
    Logger.debug("GaoBus.Peer: socket closed for #{state.unique_name || "unauthenticated"}")
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info({:socket_error, reason}, state) do
    Logger.warning("GaoBus.Peer: socket error: #{inspect(reason)}")
    cleanup(state)
    {:stop, reason, state}
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
        request_recv(state.socket)
        {:noreply, %{state | auth_buffer: buffer}}
    end
  end

  defp handle_auth_line("AUTH " <> rest, state) do
    # Extract credentials from auth mechanism
    state = extract_credentials(rest, state)
    # Accept any auth mechanism for now — respond with OK
    do_send(state.socket, "OK #{@auth_guid}\r\n")
    wait_for_begin(state)
  end

  defp handle_auth_line("BEGIN", state) do
    # Client sent BEGIN — switch to binary protocol
    Logger.debug("GaoBus.Peer: auth complete, entering binary mode")
    state = %{state | state: :connected, buffer: state.auth_buffer}
    # Process any binary data already buffered from the auth phase
    {state, buffer} = process_messages(state, state.buffer, [])
    request_recv(state.socket)
    {:noreply, %{state | buffer: buffer}}
  end

  defp handle_auth_line("NEGOTIATE_UNIX_FD", state) do
    # Agree to FD passing over Unix domain sockets
    do_send(state.socket, "AGREE_UNIX_FD\r\n")
    wait_for_begin(%{state | fd_passing: true})
  end

  defp handle_auth_line(line, state) do
    Logger.debug("GaoBus.Peer: unknown auth line: #{inspect(line)}")
    do_send(state.socket, "ERROR\r\n")
    wait_for_begin(state)
  end

  defp wait_for_begin(state) do
    # Check if BEGIN is already in the buffer
    case extract_line(state.auth_buffer) do
      {"BEGIN", rest} ->
        Logger.debug("GaoBus.Peer: auth complete, entering binary mode")
        state = %{state | state: :connected, buffer: rest}
        {state, buffer} = process_messages(state, state.buffer, [])
        request_recv(state.socket)
        {:noreply, %{state | buffer: buffer}}

      {line, rest} ->
        # Another auth line before BEGIN
        handle_auth_line(line, %{state | auth_buffer: rest})

      nil ->
        request_recv(state.socket)
        {:noreply, state}
    end
  end

  # --- Message processing ---

  defp process_messages(state, buffer, _fds) when byte_size(buffer) < 16, do: {state, buffer}

  defp process_messages(state, buffer, fds) do
    case Message.decode_message(buffer) do
      {:ok, msg, rest} ->
        # Stamp sender and attach received FDs
        msg = %{msg | sender: state.unique_name, fds: take_fds(fds, msg.unix_fds)}
        GaoBus.Router.route(msg, self())
        # Remaining FDs (if any) belong to the next message
        remaining_fds = drop_fds(fds, msg.unix_fds)
        process_messages(state, rest, remaining_fds)

      {:error, :insufficient_data} ->
        {state, buffer}

      {:error, reason} ->
        Logger.error("GaoBus.Peer: decode error: #{inspect(reason)}")
        {state, buffer}
    end
  end

  # Take the first N FDs for this message
  defp take_fds(_fds, nil), do: []
  defp take_fds(fds, n) when is_integer(n), do: Enum.take(fds, n)

  # Drop the first N FDs (consumed by this message)
  defp drop_fds(fds, nil), do: fds
  defp drop_fds(fds, n) when is_integer(n), do: Enum.drop(fds, n)

  # --- Socket I/O using :socket module ---

  defp request_recv(socket) do
    case :socket.recvmsg(socket, 0, @ctrl_buf_size, [], :nowait) do
      {:ok, msg_hdr} ->
        # Data immediately available — send to self
        data = IO.iodata_to_binary(Map.get(msg_hdr, :iov, []))
        fds = extract_fds(Map.get(msg_hdr, :ctrl, []))
        send(self(), {:immediate_data, data, fds})

      {:select, _select_info} ->
        # Will receive {:'$socket', socket, :select, info} when data arrives
        :ok

      {:error, reason} ->
        send(self(), {:socket_error, reason})
    end
  end

  defp handle_immediate_data(data, _fds, %{state: :authenticating} = state) do
    handle_auth_data(data, state)
  end

  defp handle_immediate_data(data, fds, %{state: :connected} = state) do
    buffer = state.buffer <> data
    {state, buffer} = process_messages(state, buffer, fds)
    request_recv(state.socket)
    {:noreply, %{state | buffer: buffer}}
  end

  defp do_recv(socket) do
    case :socket.recvmsg(socket, 0, @ctrl_buf_size, [], 0) do
      {:ok, msg_hdr} ->
        data = IO.iodata_to_binary(Map.get(msg_hdr, :iov, []))
        fds = extract_fds(Map.get(msg_hdr, :ctrl, []))
        {:ok, data, fds}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_send(socket, data) do
    :socket.sendmsg(socket, %{iov: [IO.iodata_to_binary(data)]})
  end

  defp do_send_with_fds(socket, data, fds) when fds == [] do
    do_send(socket, data)
  end

  defp do_send_with_fds(socket, data, fds) do
    fds_binary = Enum.reduce(fds, <<>>, fn fd, acc -> acc <> <<fd::native-32>> end)

    cmsg = %{level: :socket, type: :rights, data: fds_binary}

    :socket.sendmsg(socket, %{
      iov: [IO.iodata_to_binary(data)],
      ctrl: [cmsg]
    })
  end

  defp extract_fds(ctrl_list) do
    Enum.flat_map(ctrl_list, fn
      %{level: :socket, type: :rights, data: data} ->
        decode_fd_binary(data)

      _ ->
        []
    end)
  end

  defp decode_fd_binary(<<>>), do: []

  defp decode_fd_binary(<<fd::native-32, rest::binary>>) do
    [fd | decode_fd_binary(rest)]
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

    :socket.close(state.socket)
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
