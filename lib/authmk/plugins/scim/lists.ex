defmodule Authmk.Plugins.SCIM.Lists do
  @moduledoc false
  # List answers (RFC 7644 3.4.2): filtering, 1-based paging, and `meta`.

  import Ecto.Query

  alias Authmk.Plugins.SCIM.{Config, Filter}
  alias Authmk.{Store, URL}

  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  @doc "`{:ok, total, start_index, rows}` for the page asked for, or `{:error, detail}`."
  def page(ctx, model, query, params, attributes) do
    max = Config.opts(ctx)[:max_results]
    start = max(integer(params["startIndex"], 1), 1)
    count = integer(params["count"], max) |> max(0) |> min(max)

    with {:ok, query} <- filtered(query, params["filter"], attributes) do
      total = Store.count(ctx, model, exclude(query, :select) |> exclude(:order_by))
      rows = Store.list(ctx, model, query |> offset(^(start - 1)) |> limit(^count))
      {:ok, total, start, rows}
    end
  end

  defp filtered(query, nil, _attributes), do: {:ok, query}

  defp filtered(query, filter, attributes) do
    with {:ok, ast} <- Filter.parse(filter),
         {:ok, condition} <- Filter.to_dynamic(ast, attributes),
         do: {:ok, where(query, ^condition)}
  end

  defp integer(value, _default) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _invalid -> default
    end
  end

  defp integer(_value, default), do: default

  @doc "A ListResponse."
  def response(total, start, resources) do
    %{
      schemas: [@list_schema],
      totalResults: total,
      startIndex: start,
      itemsPerPage: length(resources),
      Resources: resources
    }
  end

  @doc "A resource's `meta`."
  def meta(ctx, type, path, record) do
    %{
      resourceType: type,
      created: record.inserted_at,
      lastModified: record.updated_at,
      location: URL.endpoint(ctx, path <> to_string(record.id))
    }
  end
end
