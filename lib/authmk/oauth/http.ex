defmodule Authmk.OAuth.HTTP do
  @moduledoc """
  Outbound HTTP for OAuth: token exchanges, user info and JWKS.

  Redirects are never followed, so a provider response can't point authmk at
  an internal address (server-side request forgery). Requests time out after
  10 seconds and aren't retried. `advanced: [http_options: ...]` adds Req
  options, for example a test stub.
  """

  alias Authmk.Context

  @defaults [
    redirect: false,
    retry: false,
    receive_timeout: 10_000,
    connect_options: [timeout: 5_000]
  ]

  @type response :: {:ok, pos_integer(), term()} | {:error, term()}

  @doc "GET request. `headers` is a list of `{name, value}`."
  @spec get(Context.t(), String.t(), [{String.t(), String.t()}]) :: response()
  def get(ctx, url, headers \\ []), do: request(ctx, method: :get, url: url, headers: headers)

  @doc "POST with a form body."
  @spec post_form(Context.t(), String.t(), map() | keyword(), [{String.t(), String.t()}]) ::
          response()
  def post_form(ctx, url, form, headers \\ []),
    do: request(ctx, method: :post, url: url, form: form, headers: headers)

  @doc "POST with a JSON body, or with no body when `body` is `nil`."
  @spec post_json(Context.t(), String.t(), term(), [{String.t(), String.t()}]) :: response()
  def post_json(ctx, url, body, headers \\ []) do
    body = if is_nil(body), do: [], else: [json: body]
    request(ctx, [method: :post, url: url, headers: headers] ++ body)
  end

  @doc """
  GET of a small document from an address someone else chose: the body is
  read raw (never decoded) and refused past `max_bytes`, so a huge or
  endless answer can't exhaust memory. Returns the status, body and headers.
  """
  @spec get_limited(Context.t(), String.t(), pos_integer()) ::
          {:ok, pos_integer(), binary(), map()} | {:error, :too_large | term()}
  def get_limited(%Context{config: config}, url, max_bytes) do
    opts =
      @defaults
      |> Keyword.merge(config.advanced[:http_options] || [])
      |> Keyword.merge(
        method: :get,
        url: url,
        decode_body: false,
        receive_timeout: 5_000,
        headers: [{"user-agent", "authmk"}, {"accept", "application/json"}],
        into: &collect(&1, &2, max_bytes)
      )

    case Req.request(opts) do
      {:ok, %Req.Response{private: %{body: :too_large}}} ->
        {:error, :too_large}

      {:ok, %Req.Response{status: status, headers: headers} = response} ->
        {:ok, status, response.private[:body] || "", headers}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp collect({:data, data}, {request, response}, max_bytes) do
    body = (response.private[:body] || "") <> data

    if byte_size(body) > max_bytes,
      do: {:halt, {request, Req.Response.put_private(response, :body, :too_large)}},
      else: {:cont, {request, Req.Response.put_private(response, :body, body)}}
  end

  defp request(%Context{config: config}, opts) do
    opts =
      @defaults
      |> Keyword.merge(config.advanced[:http_options] || [])
      |> Keyword.merge(opts)
      |> Keyword.update(
        :headers,
        [],
        &[{"user-agent", "authmk"}, {"accept", "application/json"} | &1]
      )

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      {:error, exception} -> {:error, exception}
    end
  end
end
