defmodule Authmk.Router.Form do
  @moduledoc false
  # HTML forms posting straight to authmk's endpoints, without JavaScript
  # (Authmk.Components): a form post (urlencoded) with a non-empty
  # `authmk_redirect` field gets redirects instead of JSON.
  #
  #   * success: 303 to `authmk_redirect`, or to `authmk_two_factor_redirect`
  #     when a second factor is due, or to the URL the endpoint answered
  #     with (like a social provider's);
  #   * error: 303 to `authmk_error_redirect`, else back to the form's page
  #     (the Referer's path), else `authmk_redirect`, with `?error=<code>`.
  #
  # The targets must be safe redirects (relative paths or trusted origins),
  # checked before the endpoint runs. Origin checks apply as to any post.

  alias Authmk.{Context, Error, Origin, URL}

  @fields %{
    "authmk_redirect" => :success,
    "authmk_error_redirect" => :error,
    "authmk_two_factor_redirect" => :two_factor
  }

  @doc "The form's redirects (or nil when it isn't one), and the params without them."
  def read(conn, params) do
    if form_post?(conn) and string(params["authmk_redirect"]) != nil do
      form = for {field, key} <- @fields, into: %{}, do: {key, string(params[field])}
      form = %{form | error: form.error || referer_path(conn)}
      {form, Map.drop(params, Map.keys(@fields))}
    else
      {nil, params}
    end
  end

  defp form_post?(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      ["application/x-www-form-urlencoded" <> _ | _] -> true
      ["multipart/form-data" <> _ | _] -> true
      _other -> false
    end
  end

  # Only the path and query of the page the form was on, without an earlier
  # error: a relative path, so it can't lead off-site.
  defp referer_path(conn) do
    with [referer | _] <- Plug.Conn.get_req_header(conn, "referer"),
         %URI{path: "/" <> _ = path, query: query} <- URI.parse(referer) do
      case query && query |> URI.decode_query() |> Map.delete("error") do
        nil -> path
        empty when empty == %{} -> path
        rest -> path <> "?" <> URI.encode_query(rest)
      end
    else
      _none -> nil
    end
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  @doc "`:ok` when every target is a safe redirect."
  def check(_ctx, nil), do: :ok

  def check(%Context{} = ctx, form) do
    if Enum.all?(Map.values(form), &Origin.safe_redirect?(ctx, &1)),
      do: :ok,
      else: {:error, Error.new(:invalid_callback_url)}
  end

  @doc "The endpoint's result as the form's redirect. `ctx`: for errors that come without one."
  def result(result, nil, _ctx), do: result
  def result({:ok, body, ctx}, form, _ctx), do: {:see_other, success(body, form), ctx}
  def result({:error, error, ctx}, form, _ctx), do: {:see_other, failure(error, form), ctx}
  def result({:error, error}, form, ctx), do: {:see_other, failure(error, form), ctx}

  # Redirects, pages and protocol JSON stay as they are.
  def result(other, _form, _ctx), do: other

  defp success(%{redirect: true, url: url}, _form) when is_binary(url), do: url
  defp success(%{two_factor_redirect: true}, form), do: form.two_factor || form.success
  defp success(_body, form), do: form.success

  defp failure(%Error{code: code}, form),
    do: URL.append_query(form.error || form.success, error: code)
end
