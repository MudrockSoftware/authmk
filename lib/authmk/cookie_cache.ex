defmodule Authmk.CookieCache do
  @moduledoc """
  Caches the session and user in a short-lived cookie, so reading the session
  doesn't need the database.

      session: [cookie_cache: [enabled: true, max_age: 300, strategy: :signed]]

  `:signed` cookies are readable by the browser but can't be changed;
  `:encrypted` ones can't be read either. The cache is bound to the session
  token, so it can't be moved to another session.

  Only read paths use the cache: `GET /get-session` and
  `Authmk.Plug.FetchSession`. Endpoints that change anything always check
  the database. A revoked session can still *read* its cached data on other
  devices until the cache expires (`max_age`). Pass
  `disable_cookie_cache=true` to `GET /get-session` to force a fresh read, or
  change `version` to invalidate every cache at once.
  """

  alias Authmk.{Context, Cookies, Crypto, Serializer, Store, Token}

  @purpose "session-data"

  @doc "Whether the cookie cache is on."
  @spec enabled?(Authmk.Config.t()) :: boolean()
  def enabled?(config), do: config.session[:cookie_cache][:enabled]

  @doc "Writes the cache for the context's session and user, when enabled."
  @spec put(Context.t(), boolean()) :: Context.t()
  def put(%Context{config: config, session: session} = ctx, remember_me) do
    if enabled?(config) and session do
      cache = config.session[:cookie_cache]

      payload =
        JSON.encode!(%{
          "session" => Serializer.session(ctx, session),
          "user" => Serializer.user(ctx, ctx.user),
          "token_hash" => session.token,
          "expires_at" => System.system_time(:second) + cache[:max_age],
          "version" => cache[:version]
        })

      max_age = if remember_me, do: cache[:max_age]
      Cookies.put_session_data(ctx, encode(config, cache[:strategy], payload), max_age)
    else
      ctx
    end
  end

  @doc """
  Reads the cache for `token`. Returns `{:ok, session, user}` with partly
  loaded structs (only fields with `returned: true`), or `:miss`.
  """
  @spec read(Context.t(), String.t()) :: {:ok, struct(), struct()} | :miss
  def read(%Context{config: config} = ctx, token) do
    cache = config.session[:cookie_cache]

    with value when is_binary(value) <- Cookies.session_data(ctx),
         {:ok, json} <- decode(config, cache[:strategy], value),
         {:ok, payload} <- JSON.decode(json),
         true <- valid?(payload, token, cache[:version]) do
      {:ok, load(ctx, :session, payload["session"]), load(ctx, :user, payload["user"])}
    else
      _ -> :miss
    end
  end

  defp valid?(payload, token, version) do
    now = System.system_time(:second)

    with %{
           "token_hash" => hash,
           "version" => ^version,
           "expires_at" => expires_at,
           "session" => %{"expires_at" => session_expires_at}
         }
         when is_binary(hash) and is_integer(expires_at) and is_binary(session_expires_at) <-
           payload,
         true <- Plug.Crypto.secure_compare(hash, Token.hash(token)),
         true <- expires_at > now,
         {:ok, session_expires_at, _offset} <- DateTime.from_iso8601(session_expires_at) do
      DateTime.to_unix(session_expires_at) > now
    else
      _ -> false
    end
  end

  defp load(ctx, model, data), do: Ecto.embedded_load(Store.module(ctx, model), data, :json)

  defp encode(config, :signed, payload), do: Crypto.sign(config, @purpose, payload)
  defp encode(config, :encrypted, payload), do: Crypto.encrypt(config, @purpose, payload)

  defp decode(config, :signed, value), do: Crypto.verify(config, @purpose, value)
  defp decode(config, :encrypted, value), do: Crypto.decrypt(config, @purpose, value)
end
