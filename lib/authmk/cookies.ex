defmodule Authmk.Cookies do
  @moduledoc """
  Auth cookies:

    * `session_token`: the session token, signed with the secret. The
      database only has the token's hash.
    * `session_data`: the cookie cache (see `Authmk.CookieCache`), when enabled.
    * `dont_remember`: marks sessions created without "remember me", so
      refreshing them keeps the cookie browser-session-only.

  All are `HttpOnly` and `SameSite=Lax` by default. When `base_url` is HTTPS
  they are `Secure` and their names get the `__Secure-` prefix. Each cookie
  can override its name and attributes:

      cookies: [session_token: [name: "sid", same_site: "Strict"]]
  """

  alias Authmk.{Config, Context, Crypto}

  @suffixes [
    session_token: "session_token",
    session_data: "session_data",
    dont_remember: "dont_remember"
  ]

  @type cookie :: :session_token | :session_data | :dont_remember

  @doc "Name of a cookie."
  @spec name(Config.t(), cookie()) :: String.t()
  def name(config, cookie) do
    case config.cookies[cookie][:name] do
      nil ->
        name = "#{config.cookies[:prefix]}.#{Keyword.fetch!(@suffixes, cookie)}"
        if secure?(config), do: "__Secure-" <> name, else: name

      name ->
        name
    end
  end

  @doc "Sets the signed session token cookie."
  @spec put_session(Context.t(), String.t(), boolean()) :: Context.t()
  def put_session(%Context{config: config} = ctx, token, remember_me) do
    signed = Crypto.sign(config, "session-token", token)
    max_age = if remember_me, do: config.session[:expires_in]
    ctx = put(ctx, :session_token, signed, max_age)

    if remember_me,
      do: delete(ctx, :dont_remember),
      else: put(ctx, :dont_remember, Crypto.sign(config, "dont-remember", "true"), nil)
  end

  @doc """
  The session token from the request: `{:ok, token}`, `:none` without a
  cookie, or `:invalid` when the signature doesn't match.
  """
  @spec session_token(Context.t()) :: {:ok, String.t()} | :none | :invalid
  def session_token(%Context{conn: conn, config: config}) do
    case conn.req_cookies[name(config, :session_token)] do
      nil -> :none
      signed -> with :error <- Crypto.verify(config, "session-token", signed), do: :invalid
    end
  end

  @doc "Whether the request's session was created with remember me."
  @spec remember_me?(Context.t()) :: boolean()
  def remember_me?(%Context{conn: conn, config: config}) do
    signed = conn.req_cookies[name(config, :dont_remember)]
    not (is_binary(signed) and Crypto.verify(config, "dont-remember", signed) == {:ok, "true"})
  end

  @doc "Raw value of the session data cookie, or `nil`."
  @spec session_data(Context.t()) :: String.t() | nil
  def session_data(%Context{conn: conn, config: config}),
    do: conn.req_cookies[name(config, :session_data)]

  @doc "Sets the session data cookie."
  @spec put_session_data(Context.t(), String.t(), pos_integer() | nil) :: Context.t()
  def put_session_data(ctx, value, max_age), do: put(ctx, :session_data, value, max_age)

  @doc "Deletes one cookie."
  @spec delete(Context.t(), cookie()) :: Context.t()
  def delete(%Context{config: config} = ctx, cookie) do
    Context.delete_cookie(ctx, name(config, cookie), attributes(config, cookie, nil))
  end

  @doc "Deletes every session cookie."
  @spec clear_session(Context.t()) :: Context.t()
  def clear_session(ctx) do
    ctx |> delete(:session_token) |> delete(:session_data) |> delete(:dont_remember)
  end

  @doc "Whether cookies are marked `Secure`."
  @spec secure?(Config.t()) :: boolean()
  def secure?(config) do
    case config.cookies[:secure] do
      :auto -> String.starts_with?(config.base_url, "https://")
      secure -> secure
    end
  end

  defp put(%Context{config: config} = ctx, cookie, value, max_age) do
    Context.put_cookie(ctx, name(config, cookie), value, attributes(config, cookie, max_age))
  end

  defp attributes(config, cookie, max_age) do
    overrides = config.cookies[cookie] || []

    [
      http_only: true,
      secure: secure?(config),
      same_site: Keyword.get(overrides, :same_site, config.cookies[:same_site]),
      path: "/",
      domain: Keyword.get(overrides, :domain, config.cookies[:domain]),
      max_age: max_age
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
