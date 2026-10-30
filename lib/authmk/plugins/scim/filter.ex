defmodule Authmk.Plugins.SCIM.Filter do
  @moduledoc false
  # SCIM filters (RFC 7644 3.4.2.2), the part identity providers use:
  # `attr op value` and `attr pr`, joined with `and` / `or` (and binds
  # tighter), with parentheses. Operators: eq, ne, co, sw, ew, pr. Strings
  # compare case-insensitively, as SCIM's caseExact=false attributes do.
  #
  # Filters come from the network: they're length-limited, depth-limited,
  # and never turned into atoms. They become Ecto `dynamic` expressions over
  # the attributes a resource allows, so nothing reaches SQL unescaped.

  import Ecto.Query

  @max_length 1_000
  @max_comparisons 20
  @max_depth 5
  @operators ~w(eq ne co sw ew)

  @type ast ::
          {:and, ast(), ast()}
          | {:or, ast(), ast()}
          | {:cmp, String.t(), String.t(), term()}
          | {:pr, String.t()}

  @doc "Parses a filter: `{:ok, ast}` or `{:error, description}`."
  def parse(filter) when is_binary(filter) and byte_size(filter) <= @max_length do
    with {:ok, tokens} <- tokenize(filter, []),
         :ok <- check_size(tokens),
         {:ok, ast, []} <- parse_or(tokens, 0) do
      {:ok, ast}
    else
      {:ok, _ast, [_ | _]} -> {:error, "Unexpected input after the filter"}
      {:error, description} -> {:error, description}
    end
  end

  def parse(filter) when is_binary(filter), do: {:error, "The filter is too long"}
  def parse(_filter), do: {:error, "The filter must be a string"}

  defp check_size(tokens) do
    comparisons =
      Enum.count(tokens, fn
        {:word, word} -> String.downcase(word) in ["pr" | @operators]
        _other -> false
      end)

    if comparisons <= @max_comparisons,
      do: :ok,
      else: {:error, "The filter has too many comparisons"}
  end

  # Tokens: {:word, text}, {:string, text}, :open, :close.
  defp tokenize(<<>>, tokens), do: {:ok, Enum.reverse(tokens)}

  defp tokenize(<<c, rest::binary>>, tokens) when c in [?\s, ?\t, ?\n, ?\r],
    do: tokenize(rest, tokens)

  defp tokenize(<<?(, rest::binary>>, tokens), do: tokenize(rest, [:open | tokens])
  defp tokenize(<<?), rest::binary>>, tokens), do: tokenize(rest, [:close | tokens])

  defp tokenize(<<?", rest::binary>>, tokens) do
    case read_string(rest, []) do
      {:ok, text, rest} -> tokenize(rest, [{:string, text} | tokens])
      :error -> {:error, "Unterminated string"}
    end
  end

  defp tokenize(input, tokens) do
    case Regex.run(~r/\A[A-Za-z0-9_.:\-\$]+/, input) do
      [word] ->
        tokenize(binary_part(input, byte_size(word), byte_size(input) - byte_size(word)), [
          {:word, word} | tokens
        ])

      nil ->
        {:error, "Unexpected character in the filter"}
    end
  end

  defp read_string(<<?\\, c, rest::binary>>, acc) when c in [?", ?\\],
    do: read_string(rest, [c | acc])

  defp read_string(<<?", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp read_string(<<c::utf8, rest::binary>>, acc), do: read_string(rest, [<<c::utf8>> | acc])
  defp read_string(_input, _acc), do: :error

  defp parse_or(tokens, depth) do
    with {:ok, left, rest} <- parse_and(tokens, depth), do: more_or(left, rest, depth)
  end

  defp more_or(left, [{:word, word} | rest], depth) do
    if String.downcase(word) == "or" do
      with {:ok, right, rest} <- parse_and(rest, depth),
           do: more_or({:or, left, right}, rest, depth)
    else
      {:ok, left, [{:word, word} | rest]}
    end
  end

  defp more_or(left, rest, _depth), do: {:ok, left, rest}

  defp parse_and(tokens, depth) do
    with {:ok, left, rest} <- parse_term(tokens, depth), do: more_and(left, rest, depth)
  end

  defp more_and(left, [{:word, word} | rest], depth) do
    if String.downcase(word) == "and" do
      with {:ok, right, rest} <- parse_term(rest, depth),
           do: more_and({:and, left, right}, rest, depth)
    else
      {:ok, left, [{:word, word} | rest]}
    end
  end

  defp more_and(left, rest, _depth), do: {:ok, left, rest}

  defp parse_term([:open | _rest], depth) when depth >= @max_depth,
    do: {:error, "The filter is nested too deep"}

  defp parse_term([:open | rest], depth) do
    case parse_or(rest, depth + 1) do
      {:ok, ast, [:close | rest]} -> {:ok, ast, rest}
      {:ok, _ast, _rest} -> {:error, "Missing )"}
      error -> error
    end
  end

  defp parse_term([{:word, attr}, {:word, op} | rest], _depth) do
    case {String.downcase(op), rest} do
      {"pr", rest} ->
        {:ok, {:pr, attr}, rest}

      {op, [value | rest]} when op in @operators ->
        with {:ok, value} <- value(value), do: {:ok, {:cmp, op, attr, value}, rest}

      {op, _rest} when op in ~w(gt ge lt le) ->
        {:error, "The #{op} operator isn't supported"}

      _other ->
        {:error, "Expected an operator after #{attr}"}
    end
  end

  defp parse_term(_tokens, _depth), do: {:error, "Expected a comparison"}

  defp value({:string, text}), do: {:ok, text}
  defp value({:word, "true"}), do: {:ok, true}
  defp value({:word, "false"}), do: {:ok, false}
  defp value({:word, "null"}), do: {:ok, nil}
  defp value(_token), do: {:error, "Expected a value"}

  @doc """
  The filter as an Ecto `dynamic`. `attributes` maps lowercase attribute
  paths to `{binding, field}` for the resource's query (`:root` or
  `:link`). Unknown attributes are an error.
  """
  def to_dynamic({:and, left, right}, attributes) do
    with {:ok, left} <- to_dynamic(left, attributes),
         {:ok, right} <- to_dynamic(right, attributes),
         do: {:ok, dynamic(^left and ^right)}
  end

  def to_dynamic({:or, left, right}, attributes) do
    with {:ok, left} <- to_dynamic(left, attributes),
         {:ok, right} <- to_dynamic(right, attributes),
         do: {:ok, dynamic(^left or ^right)}
  end

  def to_dynamic({:pr, attr}, attributes) do
    with {:ok, field} <- field(attr, attributes), do: {:ok, dynamic(not is_nil(^field))}
  end

  def to_dynamic({:cmp, op, attr, value}, attributes) do
    with {:ok, field} <- field(attr, attributes), do: compare(op, field, value)
  end

  defp field(attr, attributes) do
    case Map.fetch(attributes, String.downcase(attr)) do
      {:ok, {:root, name}} -> {:ok, dynamic([root: r], field(r, ^name))}
      {:ok, {:link, name}} -> {:ok, dynamic([link: l], field(l, ^name))}
      :error -> {:error, "Can't filter on #{attr}"}
    end
  end

  defp compare("eq", field, nil), do: {:ok, dynamic(is_nil(^field))}
  defp compare("ne", field, nil), do: {:ok, dynamic(not is_nil(^field))}
  # Typed: through a dynamic field, Ecto can't tell the adapter it's a boolean.
  defp compare("eq", field, value) when is_boolean(value),
    do: {:ok, dynamic(^field == type(^value, :boolean))}

  defp compare("ne", field, value) when is_boolean(value),
    do: {:ok, dynamic(^field != type(^value, :boolean))}

  defp compare("eq", field, value) when is_binary(value),
    do: {:ok, dynamic(fragment("lower(?)", ^field) == ^String.downcase(value))}

  defp compare("ne", field, value) when is_binary(value),
    do: {:ok, dynamic(fragment("lower(?)", ^field) != ^String.downcase(value))}

  defp compare("co", field, value) when is_binary(value),
    do: like(field, "%" <> escape(value) <> "%")

  defp compare("sw", field, value) when is_binary(value), do: like(field, escape(value) <> "%")
  defp compare("ew", field, value) when is_binary(value), do: like(field, "%" <> escape(value))
  defp compare(op, _field, _value), do: {:error, "#{op} needs a string"}

  # ESCAPE works the same on SQLite, PostgreSQL, MySQL and MariaDB.
  defp like(field, pattern),
    do: {:ok, dynamic(fragment("lower(?) LIKE ? ESCAPE '!'", ^field, ^pattern))}

  defp escape(value) do
    value
    |> String.downcase()
    |> String.replace("!", "!!")
    |> String.replace("%", "!%")
    |> String.replace("_", "!_")
  end
end
