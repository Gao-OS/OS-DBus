defmodule ExDBus.Connection do
  @moduledoc """
  GenServer managing a single D-Bus connection lifecycle.

  Handles transport connection, authentication, serial number assignment,
  and message dispatch.

  ## States

      :disconnected → :connecting → :authenticating → :connected

  ## Usage

      {:ok, conn} = ExDBus.Connection.start_link(address: "unix:path=/var/run/dbus/system_bus_socket")
      {:ok, reply} = ExDBus.Connection.call(conn, message)
  """

  use GenServer

  alias ExDBus.{Address, Message}

  require Logger

  defstruct [
    :transport_mod,
    :transport,
    :auth_mod,
    :auth_state,
    :guid,
    :address,
    :owner,
    state: :disconnected,
    serial: 1,
    pending_calls: %{},
    buffer: <<>>,
    opts: []
  ]

  @type t :: %__MODULE__{}

  # --- Client API ---

  @doc """
  Start a connection process.

  ## Options

    * `:address` - D-Bus address string (required unless `:transport_mod` given)
    * `:auth_mod` - Authentication module (default: `ExDBus.Auth.External`)
    * `:auth_opts` - Options passed to auth module init
    * `:transport_mod` - Transport module override
    * `:transport_opts` - Options passed to transport connect
    * `:name` - GenServer name registration
  """
  def start_link(opts) do
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Send a method_call and wait for the reply synchronously.

  Assigns a serial number automatically. Returns `{:ok, reply_message}` or `{:error, reason}`.
  """
  def call(conn, %Message{type: :method_call} = msg, timeout \\ 5_000) do
    GenServer.call(conn, {:call, msg}, timeout)
  end

  @doc """
  Send a message without waiting for a reply (signals, replies, errors).
  """
  def cast(conn, %Message{} = msg) do
    GenServer.cast(conn, {:send, msg})
  end

  @doc """
  Send a signal message.
  """
  def send_signal(conn, %Message{type: :signal} = msg) do
    GenServer.cast(conn, {:send, msg})
  end

  @doc """
  Get the current connection state.
  """
  def get_state(conn) do
    GenServer.call(conn, :get_state)
  end

  @doc """
  Get the server GUID obtained during authentication.
  """
  def get_guid(conn) do
    GenServer.call(conn, :get_guid)
  end

  @doc """
  Disconnect and stop the connection.
  """
  def disconnect(conn) do
    GenServer.call(conn, :disconnect)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner, self())
    address_str = Keyword.fetch!(opts, :address)
    auth_mod = Keyword.get(opts, :auth_mod, ExDBus.Auth.External)
    auth_opts = Keyword.get(opts, :auth_opts, [])
    transport_opts = Keyword.get(opts, :transport_opts, [])

    {:ok, [parsed_address | _]} = Address.parse(address_str)

    transport_mod =
      case Keyword.get(opts, :transport_mod) do
        nil -> Address.transport_for(parsed_address)
        mod -> mod
      end

    state = %__MODULE__{
      address: address_str,
      transport_mod: transport_mod,
      auth_mod: auth_mod,
      owner: owner,
      state: :connecting,
      opts: transport_opts
    }

    # Start connection asynchronously
    send(self(), {:do_connect, parsed_address, auth_opts})

    {:ok, state}
  end

  @impl true
  def handle_call({:call, msg}, from, %{state: :connected} = state) do
    {serial, state} = next_serial(state)
    msg = %{msg | serial: serial}

    case do_send_message(msg, state) do
      :ok ->
        pending = Map.put(state.pending_calls, serial, from)
        {:noreply, %{state | pending_calls: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, _msg}, _from, state) do
    {:reply, {:error, {:not_connected, state.state}}, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:get_guid, _from, state) do
    {:reply, state.guid, state}
  end

  def handle_call(:disconnect, _from, state) do
    state = do_disconnect(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:send, msg}, %{state: :connected} = state) do
    {serial, state} = next_serial(state)
    msg = %{msg | serial: serial}
    do_send_message(msg, state)
    {:noreply, state}
  end

  def handle_cast({:send, _msg}, state) do
    Logger.warning("ExDBus.Connection: cannot send, state=#{state.state}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:do_connect, parsed_address, auth_opts}, state) do
    raw_address = Address.to_connect_string(parsed_address)

    case state.transport_mod.connect(raw_address, state.opts) do
      {:ok, transport} ->
        state = %{state | transport: transport, state: :authenticating}
        start_auth(state, auth_opts)

      {:error, reason} ->
        Logger.error("ExDBus.Connection: connect failed: #{inspect(reason)}")
        notify_owner(state, {:connection_error, reason})
        {:noreply, %{state | state: :disconnected}}
    end
  end

  # TCP/inet active messages
  def handle_info({:tcp, _socket, data}, %{state: :authenticating} = state) do
    handle_auth_data(data, state)
  end

  def handle_info({:tcp, _socket, data}, %{state: :connected} = state) do
    handle_wire_data(data, state)
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info("ExDBus.Connection: socket closed")
    notify_owner(state, :disconnected)
    fail_pending_calls(state, :connection_closed)
    {:noreply, %{state | state: :disconnected, transport: nil}}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("ExDBus.Connection: socket error: #{inspect(reason)}")
    notify_owner(state, {:connection_error, reason})
    fail_pending_calls(state, {:connection_error, reason})
    {:noreply, %{state | state: :disconnected, transport: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("ExDBus.Connection: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    do_disconnect(state)
    :ok
  end

  # --- Auth flow ---

  defp start_auth(state, auth_opts) do
    auth_state = state.auth_mod.init(auth_opts)

    # Send null byte to start D-Bus auth protocol
    state.transport_mod.send(state.transport, <<0>>)

    # Get initial AUTH command
    {:send, command, auth_state} = state.auth_mod.initial_command(auth_state)

    # Send AUTH command with \r\n terminator
    state.transport_mod.send(state.transport, [command, "\r\n"])

    # Switch to active :once to receive the response
    state.transport_mod.set_active(state.transport, :once)

    {:noreply, %{state | auth_state: auth_state}}
  end

  defp handle_auth_data(data, state) do
    buffer = state.buffer <> data

    case extract_line(buffer) do
      {line, rest} ->
        case state.auth_mod.handle_line(line, state.auth_state) do
          {:ok, guid, auth_state} ->
            # Auth succeeded — send BEGIN and switch to binary protocol
            state.transport_mod.send(state.transport, "BEGIN\r\n")
            state.transport_mod.set_active(state.transport, true)

            state = %{state |
              auth_state: auth_state,
              guid: guid,
              buffer: rest,
              state: :connected
            }

            notify_owner(state, {:connected, guid})
            {:noreply, state}

          {:send, command, auth_state} ->
            state.transport_mod.send(state.transport, [command, "\r\n"])
            state.transport_mod.set_active(state.transport, :once)
            {:noreply, %{state | auth_state: auth_state, buffer: rest}}

          {:error, reason} ->
            Logger.error("ExDBus.Connection: auth failed: #{inspect(reason)}")
            notify_owner(state, {:auth_error, reason})
            do_disconnect(state)
            {:noreply, %{state | state: :disconnected}}
        end

      nil ->
        # Incomplete line, wait for more data
        state.transport_mod.set_active(state.transport, :once)
        {:noreply, %{state | buffer: buffer}}
    end
  end

  # --- Wire protocol data handling ---

  defp handle_wire_data(data, state) do
    buffer = state.buffer <> data
    {state, buffer} = process_messages(state, buffer)
    {:noreply, %{state | buffer: buffer}}
  end

  defp process_messages(state, buffer) when byte_size(buffer) < 16, do: {state, buffer}

  defp process_messages(state, buffer) do
    case Message.decode_message(buffer) do
      {:ok, msg, rest} ->
        state = dispatch_message(msg, state)
        process_messages(state, rest)

      {:error, :insufficient_data} ->
        {state, buffer}

      {:error, reason} ->
        Logger.error("ExDBus.Connection: decode error: #{inspect(reason)}")
        {state, buffer}
    end
  end

  defp dispatch_message(%Message{type: type} = msg, state)
       when type in [:method_return, :error] do
    case Map.pop(state.pending_calls, msg.reply_serial) do
      {nil, _pending} ->
        # No pending call — send to owner
        notify_owner(state, {:message, msg})
        state

      {from, pending} ->
        reply =
          case type do
            :method_return -> {:ok, msg}
            :error -> {:error, {:dbus_error, msg.error_name, msg.body}}
          end

        GenServer.reply(from, reply)
        %{state | pending_calls: pending}
    end
  end

  defp dispatch_message(msg, state) do
    # Signals, method_calls (if we're a server) go to owner
    notify_owner(state, {:message, msg})
    state
  end

  # --- Helpers ---

  defp next_serial(state) do
    serial = state.serial
    {serial, %{state | serial: serial + 1}}
  end

  defp do_send_message(msg, state) do
    data = Message.encode_message(msg)
    state.transport_mod.send(state.transport, data)
  end

  defp do_disconnect(%{transport: nil} = state), do: %{state | state: :disconnected}

  defp do_disconnect(state) do
    state.transport_mod.close(state.transport)
    %{state | transport: nil, state: :disconnected}
  end

  defp notify_owner(%{owner: owner}, event) when is_pid(owner) do
    send(owner, {:ex_dbus, event})
  end

  defp notify_owner(_, _), do: :ok

  defp fail_pending_calls(state, reason) do
    Enum.each(state.pending_calls, fn {_serial, from} ->
      GenServer.reply(from, {:error, reason})
    end)
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
end
