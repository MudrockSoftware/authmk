defmodule Authmk.Dashboard.CSV do
  @moduledoc false
  # CSV for the dashboard's exports (RFC 4180). Values that start like a
  # spreadsheet formula (=, +, -, @, tab, carriage return) get a leading
  # apostrophe, so a name like `=HYPERLINK(...)` stays text when the file
  # is opened (CSV injection).

  @formula ["=", "+", "-", "@", "\t", "\r"]

  @doc "The rows (lists of values) with a header row, as iodata."
  def encode(header, rows), do: Enum.map([header | rows], &line/1)

  defp line(values), do: [values |> Enum.map(&field/1) |> Enum.intersperse(","), "\r\n"]

  defp field(nil), do: ""
  defp field(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp field(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp field(%Date{} = value), do: Date.to_iso8601(value)
  defp field(value) when is_map(value) or is_list(value), do: field(JSON.encode!(value))

  defp field(value) do
    text = to_string(value)
    text = if String.starts_with?(text, @formula), do: "'" <> text, else: text

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: ["\"", String.replace(text, "\"", "\"\""), "\""],
      else: text
  end
end
