defmodule Authmk.Plugins.SIWE.Message do
  @moduledoc false
  # Parses Sign-In with Ethereum messages (EIP-4361). Strict: the lines must
  # be in the spec's order, and unknown or repeated fields are refused.

  @header " wants you to sign in with your Ethereum account:"
  @optional [
    {"Expiration Time", :expiration_time},
    {"Not Before", :not_before},
    {"Request ID", :request_id}
  ]

  defstruct [
    :domain,
    :address,
    :statement,
    :uri,
    :version,
    :chain_id,
    :nonce,
    :issued_at,
    :expiration_time,
    :not_before,
    :request_id,
    resources: []
  ]

  def parse(message) when is_binary(message) do
    with [header, address, "" | rest] <- String.split(message, "\n"),
         {:ok, domain} <- domain(header),
         {statement, fields} <- statement(rest),
         {:ok, required, rest} <- required(fields),
         {:ok, optional, rest} <- optional(rest, @optional, %{}),
         {:ok, resources} <- resources(rest) do
      {:ok,
       struct!(
         %__MODULE__{
           domain: domain,
           address: address,
           statement: statement,
           resources: resources
         },
         Map.merge(required, optional)
       )}
    else
      _invalid -> :error
    end
  end

  def parse(_message), do: :error

  defp domain(header) do
    case String.split(header, @header) do
      [domain, ""] when domain != "" -> {:ok, domain}
      _other -> :error
    end
  end

  # The statement is optional; when present, a blank line follows it.
  defp statement(["URI: " <> _ | _] = fields), do: {nil, fields}
  defp statement([statement, "" | fields]), do: {statement, fields}
  defp statement(_lines), do: :error

  defp required([
         "URI: " <> uri,
         "Version: 1",
         "Chain ID: " <> chain_id,
         "Nonce: " <> nonce,
         "Issued At: " <> issued_at | rest
       ]) do
    with {chain_id, ""} <- Integer.parse(chain_id),
         true <- nonce =~ ~r/^[a-zA-Z0-9]{8,}$/,
         {:ok, issued_at, _offset} <- DateTime.from_iso8601(issued_at) do
      {:ok, %{uri: uri, version: "1", chain_id: chain_id, nonce: nonce, issued_at: issued_at},
       rest}
    else
      _invalid -> :error
    end
  end

  defp required(_fields), do: :error

  # Each optional field at most once, in the spec's order.
  defp optional(lines, [], found), do: {:ok, found, lines}

  defp optional([line | rest] = lines, [{label, key} | more], found) do
    case String.split(line, label <> ": ", parts: 2) do
      ["", value] ->
        with {:ok, value} <- optional_value(key, value) do
          optional(rest, more, Map.put(found, key, value))
        end

      _other ->
        optional(lines, more, found)
    end
  end

  defp optional([], _labels, found), do: {:ok, found, []}

  defp optional_value(:request_id, value), do: {:ok, value}

  defp optional_value(_time, value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> {:ok, time}
      _invalid -> :error
    end
  end

  defp resources([]), do: {:ok, []}

  defp resources(["Resources:" | lines]) do
    if Enum.all?(lines, &String.starts_with?(&1, "- ")),
      do: {:ok, Enum.map(lines, &String.replace_prefix(&1, "- ", ""))},
      else: :error
  end

  defp resources(_lines), do: :error
end
