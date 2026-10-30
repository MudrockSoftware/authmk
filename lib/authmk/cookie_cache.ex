defmodule Authmk.CookieCache do
  @moduledoc """
  Caches the session and user in a short-lived cookie, so reading the session
  doesn't need the database.

      session: [cookie_cache: [enabled: true, max_age: 300, strategy: :signed]]

  `:signed` cookies are readable by the browser but can't be changed;
  `:encrypted` ones can't be read either. `:jwt` makes it a JWT (HS256,
  with a key derived from the secret, `kid` naming the secret's version),
  and `:jwt_jwks` a JWT signed with `Authmk.Plugins.JWT`'s keys, so other
  services can check it against the app's JWKS without the secret. The JWT
  claims are the cached `session` and `user`, `sub` (the user ID), `exp`,
  `token_hash` and `version`. The cache is bound to the session token, so it
  can't be moved to another session.

  Only read paths use the cache: `GET /get-session` and
  `Authmk.Plug.FetchSession`. Endpoints that change anything always check
  the database. A revoked session can still *read* its cached data on other
  devices until the cache expires (`max_age`). Pass
  `disable_cookie_cache=true` to `GET /get-session` to force a fresh read, or
  change `version` to invalidate every cache at once.
  """

  alias Authmk.{Context, Cookies, Crypto, Serializer, Store, Token}

  @purpose "session-data"
  @jwt_purpose "session-data-jwt"

  @doc "Whether the cookie cache is on: when enabled, and always for stateless sessions."
  @spec enabled?(Authmk.Config.t()) :: boolean()
  def enabled?(config), do: config.session[:cookie_cache][:enabled] or config.session[:stateless]

  @doc "Writes the cache for the context's session and user, when enabled."
  @spec put(Context.t(), boolean()) :: Context.t()
  def put(%Context{config: config, session: session} = ctx, remember_me) do
    if enabled?(config) and session do
      cache = config.session[:cookie_cache]

      # Stateless, the cookie is the session: it lasts as long as it does.
      {expires_at, max_age} =
        if config.session[:stateless],
          do: {DateTime.to_unix(session.expires_at), config.session[:expires_in]},
          else: {System.system_time(:second) + cache[:max_age], cache[:max_age]}

      # Through JSON: the claims hold only JSON values, as they're read back.
      payload =
        %{
          "session" => Serializer.session(ctx, session),
          "user" => Serializer.user(ctx, ctx.user),
          "sub" => to_string(ctx.user.id),
          "token_hash" => session.token,
          "expires_at" => expires_at,
          "exp" => expires_at,
          "version" => version(cache, ctx.user)
        }
        |> JSON.encode!()
        |> JSON.decode!()

      max_age = if remember_me, do: max_age
      Cookies.put_session_data(ctx, encode(ctx, cache[:strategy], payload), max_age)
    else
      ctx
    end
  end

  @doc """
  Reads the cache for `token`. Returns `{:ok, session, user}` with partly
  loaded structs (only fields with `returned: true`), or `:miss`.
  """
  @spec read(Context.t(), String.t()) :: {:ok, struct(), struct()} | :miss
  def read(ctx, token), do: read_value(ctx, Cookies.session_data(ctx), Token.hash(token))

  @doc false
  # The cache in `value` for the session with `token_hash`: for LiveViews,
  # which get the cookie's value and the hash, not the cookie.
  @spec read_value(Context.t(), String.t() | nil, String.t()) ::
          {:ok, struct(), struct()} | :miss
  def read_value(%Context{config: config} = ctx, value, token_hash) do
    cache = config.session[:cookie_cache]

    with true <- is_binary(value) and is_binary(token_hash),
         {:ok, payload} <- decode(ctx, cache[:strategy], value),
         true <- valid?(payload, token_hash),
         user = load(ctx, :user, payload["user"]),
         true <- payload["version"] == version(cache, user) do
      session = load(ctx, :session, payload["session"])
      {:ok, %{session | token: token_hash}, user}
    else
      _ -> :miss
    end
  end

  # A string, or the user's own (`fn user -> ... end`), to revoke one
  # user's caches, or stateless sessions.
  defp version(cache, user) do
    case cache[:version] do
      version when is_function(version, 1) -> to_string(version.(user))
      version -> version
    end
  end

  defp valid?(payload, token_hash) do
    now = System.system_time(:second)

    with %{
           "token_hash" => hash,
           "version" => version,
           "expires_at" => expires_at,
           "session" => %{"expires_at" => session_expires_at}
         }
         when is_binary(hash) and is_binary(version) and is_integer(expires_at) and
                is_binary(session_expires_at) <-
           payload,
         true <- Plug.Crypto.secure_compare(hash, token_hash),
         true <- expires_at > now,
         {:ok, session_expires_at, _offset} <- DateTime.from_iso8601(session_expires_at) do
      DateTime.to_unix(session_expires_at) > now
    else
      _ -> false
    end
  end

  defp load(ctx, model, data), do: Ecto.embedded_load(Store.module(ctx, model), data, :json)

  defp encode(%Context{config: config}, :signed, payload),
    do: Crypto.sign(config, @purpose, JSON.encode!(payload))

  defp encode(%Context{config: config}, :encrypted, payload),
    do: Crypto.encrypt(config, @purpose, JSON.encode!(payload))

  defp encode(%Context{config: config}, :jwt, claims) do
    [{version, secret} | _older] = config.secrets
    header = %{"alg" => "HS256", "typ" => "JWT", "kid" => "v#{version}"}
    {_jws, token} = secret |> hs256_key() |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    token
  end

  defp encode(ctx, :jwt_jwks, claims) do
    {:ok, token} = jwt_plugin!(ctx.config).sign_claims(ctx, claims, %{"typ" => "JWT"})
    token
  end

  defp decode(%Context{config: config}, :signed, value) do
    with {:ok, json} <- Crypto.verify(config, @purpose, value), do: JSON.decode(json)
  end

  defp decode(%Context{config: config}, :encrypted, value) do
    with {:ok, json} <- Crypto.decrypt(config, @purpose, value), do: JSON.decode(json)
  end

  defp decode(%Context{config: config}, :jwt, token) do
    with %JOSE.JWS{fields: %{"kid" => "v" <> version}} <- JOSE.JWT.peek_protected(token),
         {version, ""} <- Integer.parse(version),
         {^version, secret} <- List.keyfind(config.secrets, version, 0),
         {true, %JOSE.JWT{fields: claims}, _jws} <-
           JOSE.JWT.verify_strict(hs256_key(secret), ["HS256"], token) do
      {:ok, nulls_to_nil(claims)}
    else
      _invalid -> :error
    end
  rescue
    _malformed -> :error
  end

  defp decode(ctx, :jwt_jwks, token) do
    with {:ok, claims} <- jwt_plugin!(ctx.config).verified_claims(ctx, token),
         do: {:ok, nulls_to_nil(claims)}
  end

  # JOSE reads JSON's null as :null.
  defp nulls_to_nil(:null), do: nil
  defp nulls_to_nil(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, nulls_to_nil(v)} end)
  defp nulls_to_nil(list) when is_list(list), do: Enum.map(list, &nulls_to_nil/1)
  defp nulls_to_nil(value), do: value

  defp hs256_key(secret), do: JOSE.JWK.from_oct(Crypto.derive_key(secret, @jwt_purpose))

  # Found at runtime, so core doesn't depend on the plugin.
  defp jwt_plugin!(config) do
    Enum.find_value(config.plugins, fn {plugin, _opts} ->
      plugin == Authmk.Plugins.JWT and plugin
    end) || raise ArgumentError, "the :jwt_jwks cookie cache needs Authmk.Plugins.JWT"
  end
end
