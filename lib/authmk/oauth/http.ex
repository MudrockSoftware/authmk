defmodule Authmk.OAuth.HTTP do
  @moduledoc """
  Outbound HTTP for OAuth: token exchanges, user info and JWKS.

  Every outbound request authmk makes goes through here (OAuth, OpenID
  Connect discovery, JWKS, SSO, captchas, Have I Been Pwned...).

  Redirects are never followed, so a response can't point authmk at an
  internal address (server-side request forgery); `http_options` can't turn
  that back on. Requests time out after 10 seconds and aren't retried.
  `advanced: [http_options: ...]` adds Req options, for example a test stub.

  URLs that someone else chose (client metadata documents, identity
  providers registered at runtime) go through `public_hosts_only/1`.
  """

  alias Authmk.Context
  alias Authmk.OAuth.PublicTCP

  @defaults [
    redirect: false,
    retry: false,
    receive_timeout: 10_000,
    connect_options: [timeout: 5_000]
  ]

  @type response :: {:ok, pos_integer(), term()} | {:error, term()}

  @doc """
  Marks `ctx` so its requests only go to public addresses over HTTPS, for
  URLs someone else chose (server-side request forgery). The host is
  resolved when connecting, every address it resolves to must be public
  (not loopback, private, link-local or multicast), and the connection goes
  to an address that was checked, so DNS rebinding can't reach a private
  network. Other URLs fail with `:host_not_public`.
  """
  @spec public_hosts_only(Context.t()) :: Context.t()
  def public_hosts_only(ctx), do: Context.put_private(ctx, :public_hosts_only, true)

  @doc "GET request. `headers` is a list of `{name, value}`."
  @spec get(Context.t(), String.t(), [{String.t(), String.t()}]) :: response()
  def get(ctx, url, headers \\ []), do: request(ctx, method: :get, url: url, headers: headers)

  @doc "A request with a JSON body and any method (PATCH, PUT)."
  @spec request_json(Context.t(), atom(), String.t(), term(), [{String.t(), String.t()}]) ::
          response()
  def request_json(ctx, method, url, body, headers \\ []),
    do: request(ctx, method: method, url: url, json: body, headers: headers)

  @doc "DELETE request."
  @spec delete(Context.t(), String.t(), [{String.t(), String.t()}]) :: response()
  def delete(ctx, url, headers \\ []),
    do: request(ctx, method: :delete, url: url, headers: headers)

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
  def get_limited(%Context{config: config} = ctx, url, max_bytes) do
    opts =
      @defaults
      |> Keyword.merge(config.advanced[:http_options] || [])
      |> Keyword.merge(
        redirect: false,
        method: :get,
        url: url,
        decode_body: false,
        receive_timeout: 5_000,
        headers: [{"user-agent", "authmk"}, {"accept", "application/json"}],
        into: &collect(&1, &2, max_bytes)
      )

    with {:ok, opts} <- guard(ctx, opts) do
      send_limited(opts)
    end
  end

  defp send_limited(opts) do
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

  defp request(%Context{config: config} = ctx, opts) do
    opts =
      @defaults
      |> Keyword.merge(config.advanced[:http_options] || [])
      |> Keyword.merge(opts)
      |> Keyword.put(:redirect, false)
      |> Keyword.update(
        :headers,
        [],
        &[{"user-agent", "authmk"}, {"accept", "application/json"} | &1]
      )

    with {:ok, opts} <- guard(ctx, opts) do
      case Req.request(opts) do
        {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
        {:error, exception} -> {:error, exception}
      end
    end
  end

  # With `public_hosts_only/1`: HTTPS only, and connections through
  # `PublicTCP`. One module for every host, so Req keeps a single pool.
  defp guard(%Context{private: %{public_hosts_only: true}}, opts) do
    case URI.parse(to_string(opts[:url])) do
      %URI{scheme: "https", host: host} when host not in [nil, ""] ->
        connect_options =
          opts
          |> Keyword.get(:connect_options, [])
          |> Keyword.update(:transport_opts, [tcp_module: PublicTCP], fn transport_opts ->
            Keyword.put(transport_opts, :tcp_module, PublicTCP)
          end)

        {:ok, Keyword.put(opts, :connect_options, connect_options)}

      _other ->
        {:error, :host_not_public}
    end
  end

  defp guard(_ctx, opts), do: {:ok, opts}
end
