defmodule ExDBus.Proxy do
  @moduledoc """
  Client-side proxy for a remote D-Bus object.

  Wraps a Connection with a destination name and object path for
  ergonomic method calls.

  ## Usage

      {:ok, conn} = ExDBus.Connection.start_link(address: "unix:path=/tmp/gao_bus_socket")
      proxy = ExDBus.Proxy.new(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus")

      {:ok, reply} = ExDBus.Proxy.call(proxy, "org.freedesktop.DBus", "ListNames")
  """

  alias ExDBus.{Connection, Message}

  defstruct [:connection, :destination, :path]

  @type t :: %__MODULE__{
          connection: pid() | GenServer.name(),
          destination: String.t(),
          path: String.t()
        }

  @doc """
  Create a new proxy for a remote D-Bus object.
  """
  def new(connection, destination, path \\ "/") do
    %__MODULE__{
      connection: connection,
      destination: destination,
      path: path
    }
  end

  @doc """
  Call a method on the remote object.

  Returns `{:ok, reply_message}` or `{:error, reason}`.
  """
  def call(%__MODULE__{} = proxy, interface, method, opts \\ []) do
    signature = Keyword.get(opts, :signature)
    body = Keyword.get(opts, :body, [])
    timeout = Keyword.get(opts, :timeout, 5_000)

    msg =
      Message.method_call(proxy.path, interface, method,
        destination: proxy.destination,
        signature: signature,
        body: body
      )

    Connection.call(proxy.connection, msg, timeout)
  end

  @doc """
  Get a property value via org.freedesktop.DBus.Properties.Get.

  Returns `{:ok, {signature, value}}` or `{:error, reason}`.
  """
  def get_property(%__MODULE__{} = proxy, interface, property, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case call(proxy, "org.freedesktop.DBus.Properties", "Get",
           signature: "ss",
           body: [interface, property],
           timeout: timeout
         ) do
      {:ok, %Message{body: [variant]}} -> {:ok, variant}
      {:error, _} = err -> err
    end
  end

  @doc """
  Set a property value via org.freedesktop.DBus.Properties.Set.

  The value must be a `{signature, value}` variant tuple.
  """
  def set_property(%__MODULE__{} = proxy, interface, property, {_sig, _val} = variant, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    call(proxy, "org.freedesktop.DBus.Properties", "Set",
      signature: "ssv",
      body: [interface, property, variant],
      timeout: timeout
    )
  end

  @doc """
  Get all properties via org.freedesktop.DBus.Properties.GetAll.

  Returns `{:ok, [{key, {sig, value}}]}` or `{:error, reason}`.
  """
  def get_all_properties(%__MODULE__{} = proxy, interface, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case call(proxy, "org.freedesktop.DBus.Properties", "GetAll",
           signature: "s",
           body: [interface],
           timeout: timeout
         ) do
      {:ok, %Message{body: [props]}} -> {:ok, props}
      {:error, _} = err -> err
    end
  end

  @doc """
  Introspect the remote object.

  Returns `{:ok, xml_string}` or `{:error, reason}`.
  """
  def introspect(%__MODULE__{} = proxy, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case call(proxy, "org.freedesktop.DBus.Introspectable", "Introspect",
           timeout: timeout
         ) do
      {:ok, %Message{body: [xml]}} -> {:ok, xml}
      {:error, _} = err -> err
    end
  end

  @doc """
  Emit a signal from this proxy's connection.
  """
  def emit_signal(%__MODULE__{} = proxy, interface, member, opts \\ []) do
    signature = Keyword.get(opts, :signature)
    body = Keyword.get(opts, :body, [])

    signal =
      Message.signal(proxy.path, interface, member,
        destination: proxy.destination,
        signature: signature,
        body: body
      )

    Connection.send_signal(proxy.connection, signal)
  end
end
