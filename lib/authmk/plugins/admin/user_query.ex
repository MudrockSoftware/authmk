defmodule Authmk.Plugins.Admin.UserQuery do
  @moduledoc false
  # Builds the admin user list query: search, filter, sort and paginate,
  # only on the user model's own fields.

  import Ecto.Query

  @max_limit 100

  @doc "The query and the page: `{query, limit, offset}`, or an error for bad params."
  def build(module, params) do
    limit = min(params.limit || @max_limit, @max_limit)
    offset = params.offset || 0

    with {:ok, query} <- search(from(u in module), module, params),
         {:ok, query} <- filter(query, module, params),
         {:ok, query} <- sort(query, module, params) do
      {:ok, query |> limit(^limit) |> offset(^offset), limit, offset}
    end
  end

  defp search(query, _module, %{search_value: nil}), do: {:ok, query}

  defp search(query, module, %{search_value: value} = params) do
    with {:ok, field} <- field(module, params.search_field || "email", [:string]) do
      pattern =
        case params.search_operator || "contains" do
          "starts_with" -> escape(value) <> "%"
          "ends_with" -> "%" <> escape(value)
          _contains -> "%" <> escape(value) <> "%"
        end

      {:ok,
       where(
         query,
         [u],
         fragment("lower(?) LIKE ? ESCAPE '!'", field(u, ^field), ^String.downcase(pattern))
       )}
    end
  end

  defp filter(query, _module, %{filter_field: nil}), do: {:ok, query}

  defp filter(query, module, %{filter_field: name, filter_value: raw} = params) do
    with {:ok, field} <- field(module, name, :any),
         {:ok, value} <- cast(module, field, raw) do
      {:ok, compare(query, field, params.filter_operator || "eq", value)}
    end
  end

  defp compare(query, field, "ne", nil), do: where(query, [u], not is_nil(field(u, ^field)))
  defp compare(query, field, _eq, nil), do: where(query, [u], is_nil(field(u, ^field)))
  defp compare(query, field, "ne", value), do: where(query, [u], field(u, ^field) != ^value)
  defp compare(query, field, "lt", value), do: where(query, [u], field(u, ^field) < ^value)
  defp compare(query, field, "lte", value), do: where(query, [u], field(u, ^field) <= ^value)
  defp compare(query, field, "gt", value), do: where(query, [u], field(u, ^field) > ^value)
  defp compare(query, field, "gte", value), do: where(query, [u], field(u, ^field) >= ^value)

  defp compare(query, field, "contains", value) when is_binary(value) do
    pattern = "%" <> escape(String.downcase(value)) <> "%"
    where(query, [u], fragment("lower(?) LIKE ? ESCAPE '!'", field(u, ^field), ^pattern))
  end

  defp compare(query, field, _eq, value), do: where(query, [u], field(u, ^field) == ^value)

  defp sort(query, _module, %{sort_by: nil}), do: {:ok, order_by(query, [u], desc: u.inserted_at)}

  defp sort(query, module, %{sort_by: name} = params) do
    with {:ok, field} <- field(module, name, :any) do
      direction = if params.sort_direction == "desc", do: :desc, else: :asc
      {:ok, order_by(query, [u], [{^direction, field(u, ^field)}])}
    end
  end

  # Only the model's own fields, never anything the client makes up.
  defp field(module, name, types) do
    field = Enum.find(module.__schema__(:fields), &(Atom.to_string(&1) == name))
    type = field && module.__schema__(:type, field)

    cond do
      is_nil(field) -> {:error, :unknown_field}
      types == :any or type in types -> {:ok, field}
      true -> {:error, :unknown_field}
    end
  end

  defp cast(_module, _field, nil), do: {:ok, nil}

  defp cast(module, field, raw) do
    case Ecto.Type.cast(module.__schema__(:type, field), raw) do
      {:ok, value} -> {:ok, value}
      _invalid -> {:error, :invalid_value}
    end
  end

  # LIKE wildcards in the search are literal.
  defp escape(value), do: String.replace(value, ["!", "%", "_"], &("!" <> &1))
end
