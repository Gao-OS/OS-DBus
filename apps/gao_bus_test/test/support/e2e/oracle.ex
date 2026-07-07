defmodule GaoBusTest.E2E.Oracle do
  @moduledoc """
  Converts backend/client-specific replies into normalized semantic results.
  """

  alias GaoBusTest.E2E.Result.{Command, Oracle}

  def from_message(%ExDBus.Message{type: :method_return, signature: signature, body: body}) do
    %Oracle{kind: :method_return, signature: signature, body: body}
  end

  def from_message(%ExDBus.Message{type: :error, error_name: error_name, body: body}) do
    %Oracle{kind: :dbus_error, error_name: error_name, body: body}
  end

  def from_message(%ExDBus.Message{
        type: :signal,
        interface: interface,
        member: member,
        signature: signature,
        body: body
      }) do
    %Oracle{
      kind: :signal,
      interface: interface,
      member: member,
      signature: signature,
      body: body
    }
  end

  def from_ex_dbus({:ok, %ExDBus.Message{} = message}), do: {:ok, from_message(message)}

  def from_ex_dbus({:error, {:dbus_error, error_name, body}}) do
    {:ok, %Oracle{kind: :dbus_error, error_name: error_name, body: List.wrap(body)}}
  end

  def from_ex_dbus({:error, reason}), do: {:error, reason}

  def from_busctl(%Command{} = result) do
    cond do
      result.timed_out? ->
        {:error, :timeout}

      result.exit_status == 0 ->
        {:ok, %Oracle{kind: :method_return, body: parse_busctl_body(result.stdout)}}

      true ->
        {:ok,
         %Oracle{
           kind: :dbus_error,
           error_name: parse_error_name(result.stdout <> "\n" <> result.stderr),
           body: [String.trim(result.stdout <> result.stderr)]
         }}
    end
  end

  def from_gdbus(%Command{} = result) do
    cond do
      result.timed_out? ->
        {:error, :timeout}

      result.exit_status == 0 ->
        {:ok, %Oracle{kind: :method_return, body: parse_gdbus_body(result.stdout)}}

      true ->
        {:ok,
         %Oracle{
           kind: :dbus_error,
           error_name: parse_error_name(result.stdout <> "\n" <> result.stderr),
           body: [String.trim(result.stdout <> result.stderr)]
         }}
    end
  end

  def method_return?(%Oracle{kind: :method_return}), do: true
  def method_return?(_), do: false

  def dbus_error?(%Oracle{kind: :dbus_error}), do: true
  def dbus_error?(_), do: false

  def contains_body?(%Oracle{body: body}, expected), do: Enum.any?(body, &(&1 == expected))

  def body_text_contains?(%Oracle{body: body}, expected) do
    Enum.any?(body, &(to_string(&1) =~ expected))
  end

  defp parse_busctl_body(stdout) do
    stdout
    |> String.trim()
    |> case do
      "" -> []
      text -> [text]
    end
  end

  defp parse_gdbus_body(stdout) do
    stdout
    |> String.trim()
    |> String.trim_leading("(")
    |> String.trim_trailing(",)")
    |> String.trim_trailing(")")
    |> case do
      "" -> []
      text -> [parse_gdbus_scalar(text)]
    end
  end

  defp parse_gdbus_scalar("'" <> text) do
    text
    |> String.trim_trailing("'")
    |> String.replace("\\'", "'")
  end

  defp parse_gdbus_scalar(text) do
    case Integer.parse(text) do
      {integer, ""} -> integer
      _ -> text
    end
  end

  defp parse_error_name(output) do
    case Regex.run(~r/org\.freedesktop\.DBus\.Error\.[A-Za-z0-9_]+/, output) do
      [name] -> name
      nil -> "org.freedesktop.DBus.Error.Failed"
    end
  end
end
