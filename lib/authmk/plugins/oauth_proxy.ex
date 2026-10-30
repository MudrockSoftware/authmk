defmodule Authmk.Plugins.OAuthProxy do
  @moduledoc """
  Social sign-in on preview deployments and localhost, through the one
  callback URL registered with the provider: production's.

      use Authmk,
        plugins: [
          {Authmk.Plugins.OAuthProxy,
           production_url: "https://app.example.com",
           secret: System.fetch_env!("OAUTH_PROXY_SECRET")}
        ],
        trusted_origins: ["http://localhost:4000", "https://*.preview.example.com"],
        ...

  Install it, with the same options, on production and on every deployment
  that signs in through it. `production_url` is production's `base_url`,
  and every deployment mounts authmk at the same path.

  How a sign-in goes from a preview deployment:

    1. The preview starts the flow as usual (its state cookie, PKCE), but
       the provider is told to call back production, and the `state` it
       carries is wrapped: signed with `secret`, naming the preview's own
       callback URL, valid for 10 minutes.
    2. Production checks the signature, that the preview's URL is one of
       its `trusted_origins`, and that it's a callback for the same
       provider, then sends the browser there with the code and the
       preview's `state`. Production keeps nothing and signs no one in.
    3. The preview checks `state` against its cookie and exchanges the code
       itself (with production's callback URL, which the code was issued
       for), then signs the user in to its own database.

  So `secret` only lets a deployment choose where production sends a code
  among the trusted origins; the code is useless without the state cookie
  and PKCE verifier of the browser that started the flow. Still, share it
  only with deployments you trust, and keep it out of builds that run
  untrusted code.

  On production itself, sign-ins don't go through the proxy. Providers with
  their own `redirect_uri` option aren't proxied either.

  ## Options

    * `:production_url` - production's `base_url` (required)
    * `:secret` - shared by every deployment, at least 32 bytes, and not the
      app's own secret (required)

  Either can be a function of no arguments, called when the auth module
  starts, to read runtime config:

      {Authmk.Plugins.OAuthProxy,
       production_url: &MyApp.Auth.oauth_proxy_url/0,
       secret: &MyApp.Auth.oauth_proxy_secret/0}
  """

  use Authmk.Plugin

  alias Authmk.{Context, Origin, URL}

  @salt "authmk-oauth-proxy"
  @max_age 600
  @starts [:sign_in_social, :link_social, :initiate_sign_in]
  @passed_on ~w(code error error_description user device_id iss)

  @impl true
  def init(opts) do
    opts =
      opts
      |> NimbleOptions.validate!(
        production_url: [type: {:or, [:string, {:fun, 0}]}, required: true],
        secret: [type: {:or, [:string, {:fun, 0}]}, required: true]
      )
      |> Keyword.new(fn {key, value} -> {key, resolve(value)} end)

    if not (is_binary(opts[:secret]) and byte_size(opts[:secret]) >= 32),
      do: raise(ArgumentError, "Authmk.Plugins.OAuthProxy: secret must be at least 32 bytes")

    if not (is_binary(opts[:production_url]) and is_binary(Origin.origin(opts[:production_url]))),
      do: raise(ArgumentError, "Authmk.Plugins.OAuthProxy: production_url must be an http(s) URL")

    Keyword.update!(opts, :production_url, &String.trim_trailing(&1, "/"))
  end

  # Functions are called once, when the auth module starts: for values from
  # runtime config.
  defp resolve(value) when is_function(value, 0), do: value.()
  defp resolve(value), do: value

  @impl true
  def before_endpoint(endpoint, ctx) when endpoint in [:callback | @starts] do
    cond do
      production?(ctx) and endpoint == :callback ->
        bounce(ctx)

      production?(ctx) ->
        {:cont, ctx}

      true ->
        {:cont, Context.put_private(ctx, :oauth_redirect_base_url, opts(ctx)[:production_url])}
    end
  end

  def before_endpoint(_endpoint, ctx), do: {:cont, ctx}

  @impl true
  def after_endpoint(endpoint, ctx, {:ok, %{url: url} = body, result_ctx})
      when endpoint in @starts and is_binary(url),
      do: {:ok, %{body | url: wrap_state(ctx, url)}, result_ctx}

  def after_endpoint(endpoint, ctx, {:redirect, url, result_ctx}) when endpoint in @starts,
    do: {:redirect, wrap_state(ctx, url), result_ctx}

  def after_endpoint(_endpoint, _ctx, result), do: result

  # On a preview: the provider's URL, with `state` wrapped when it calls
  # back production. Other URLs (providers with their own redirect_uri,
  # error pages) are left alone.
  defp wrap_state(ctx, url) do
    if production?(ctx), do: url, else: wrap_preview_state(ctx, url)
  end

  defp wrap_preview_state(ctx, url) do
    uri = URI.parse(url)
    query = URI.query_decoder(uri.query || "") |> Enum.to_list()

    with "/callback/" <> provider <- callback_path(ctx, query),
         {"state", state} <- List.keyfind(query, "state", 0) do
      wrapped =
        sign(ctx, %{"state" => state, "to" => URL.endpoint(ctx, "/callback/" <> provider)})

      query = List.keyreplace(query, "state", 0, {"state", wrapped})
      URI.to_string(%{uri | query: URI.encode_query(query, :rfc3986)})
    else
      _not_proxied -> url
    end
  end

  # The callback path when the URL sends the provider back to production.
  defp callback_path(%Context{config: config} = ctx, query) do
    prefix = opts(ctx)[:production_url] <> config.base_path

    case List.keyfind(query, "redirect_uri", 0) do
      {"redirect_uri", ^prefix <> path} -> path
      _other -> nil
    end
  end

  # On production: a wrapped state goes back to the deployment it names.
  # Anything else is production's own sign-in.
  defp bounce(%Context{raw_params: params} = ctx) do
    with state when is_binary(state) <- params["state"],
         {:ok, %{"state" => inner, "to" => to}} <- verify(ctx, state),
         true <- returns_to_callback?(ctx, to, params["provider"]) do
      query = params |> Map.take(@passed_on) |> Map.put("state", inner) |> Enum.sort()
      {:respond, {:redirect, URL.append_query(to, query), ctx}}
    else
      _not_proxied -> {:cont, ctx}
    end
  end

  defp returns_to_callback?(ctx, to, provider) when is_binary(provider) do
    is_binary(Origin.origin(to)) and Origin.safe_redirect?(ctx, to) and
      String.ends_with?(URI.parse(to).path || "", "/callback/" <> provider)
  end

  defp returns_to_callback?(_ctx, _to, _provider), do: false

  # Without a base URL this request can't be placed: treat it as production,
  # where nothing is changed, unless it carries a valid wrapped state.
  defp production?(%Context{base_url: base_url} = ctx) when is_binary(base_url),
    do: Origin.origin(base_url) == Origin.origin(opts(ctx)[:production_url])

  defp production?(_ctx), do: true

  defp sign(ctx, data), do: Plug.Crypto.sign(opts(ctx)[:secret], @salt, data)

  defp verify(ctx, token) do
    case Plug.Crypto.verify(opts(ctx)[:secret], @salt, token, max_age: @max_age) do
      {:ok, %{} = data} -> {:ok, data}
      _invalid -> :error
    end
  end

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
