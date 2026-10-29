defmodule Authmk.Cookies do
  @moduledoc """
  Auth cookies:

    * `session_token`: the session token, signed with the secret. The
      database only has the token's hash.
    * `session_data`: the cookie cache (see `Authmk.CookieCache`), when enabled.
    * `dont_remember`: marks sessions created without "remember me", so
      refreshing them keeps the cookie browser-session-only.
    * `oauth_state`: the in-progress social sign-in (see `Authmk.OAuth.State`).

  Plugins add their own (like `two_factor`) with `put/4`, `get/2` and
  `delete/2`, named `<prefix>.<name>`.

  All are `HttpOnly` and `SameSite=Lax` by default. When `base_url` is HTTPS
  they are `Secure` and their names get the `__Secure-` prefix. Each cookie
  can override its name and attributes:

      cookies: [session_token: [name: "sid", same_site: "Strict"]]
  """

  alias Authmk.{Context, Crypto}

  @suffixes [
    session_token: "session_token",
    session_data: "session_data",
    dont_remember: "dont_remember",
    oauth_state: "oauth_state"
  ]

  @type cookie :: :session_token | :session_data | :dont_remember | :oauth_state | atom()

  @doc "Name of a cookie."
  @spec name(Context.t(), cookie()) :: String.t()
  def name(%Context{config: config} = ctx, cookie) do
    case config.cookies[cookie][:name] do
      nil ->
        name =
          "#{config.cookies[:prefix]}.#{Keyword.get(@suffixes, cookie, Atom.to_string(cookie))}"

        if secure?(ctx), do: "__Secure-" <> name, else: name

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
  def session_token(%Context{conn: conn, config: config} = ctx) do
    case conn.req_cookies[name(ctx, :session_token)] do
      nil -> :none
      signed -> with :error <- Crypto.verify(config, "session-token", signed), do: :invalid
    end
  end

  @doc "Whether the request's session was created with remember me."
  @spec remember_me?(Context.t()) :: boolean()
  def remember_me?(%Context{conn: conn, config: config} = ctx) do
    signed = conn.req_cookies[name(ctx, :dont_remember)]
    not (is_binary(signed) and Crypto.verify(config, "dont-remember", signed) == {:ok, "true"})
  end

  @doc "Raw value of the session data cookie, or `nil`."
  @spec session_data(Context.t()) :: String.t() | nil
  def session_data(%Context{conn: conn} = ctx),
    do: conn.req_cookies[name(ctx, :session_data)]

  @doc "The in-progress social sign-in cookie, or `nil`."
  @spec oauth_state(Context.t()) :: String.t() | nil
  def oauth_state(%Context{conn: conn} = ctx), do: conn.req_cookies[name(ctx, :oauth_state)]

  @doc "Sets the in-progress social sign-in cookie."
  @spec put_oauth_state(Context.t(), String.t(), pos_integer()) :: Context.t()
  def put_oauth_state(ctx, value, max_age), do: put(ctx, :oauth_state, value, max_age)

  @doc "Sets the session data cookie."
  @spec put_session_data(Context.t(), String.t(), pos_integer() | nil) :: Context.t()
  def put_session_data(ctx, value, max_age), do: put(ctx, :session_data, value, max_age)

  @doc "Raw value of a cookie from the request, or `nil`."
  @spec get(Context.t(), cookie()) :: String.t() | nil
  def get(%Context{conn: conn} = ctx, cookie), do: conn.req_cookies[name(ctx, cookie)]

  @doc """
  Sets a cookie, for `max_age` seconds (`nil`: until the browser closes).

  Cookies are `HttpOnly` unless `http_only: false` is given, for values
  the browser's scripts must read. Never pass it for secrets.
  """
  @spec put(Context.t(), cookie(), String.t(), pos_integer() | nil, keyword()) :: Context.t()
  def put(ctx, cookie, value, max_age, opts \\ []) do
    attributes = Keyword.merge(attributes(ctx, cookie, max_age), Keyword.take(opts, [:http_only]))
    Context.put_cookie(ctx, name(ctx, cookie), value, attributes)
  end

  @doc "Deletes one cookie."
  @spec delete(Context.t(), cookie()) :: Context.t()
  def delete(ctx, cookie) do
    Context.delete_cookie(ctx, name(ctx, cookie), attributes(ctx, cookie, nil))
  end

  @doc "Deletes every session cookie."
  @spec clear_session(Context.t()) :: Context.t()
  def clear_session(ctx) do
    ctx |> delete(:session_token) |> delete(:session_data) |> delete(:dont_remember)
  end

  @doc "Whether cookies are marked `Secure`: by default, when the request's base URL is HTTPS."
  @spec secure?(Context.t()) :: boolean()
  def secure?(%Context{config: config, base_url: base_url}) do
    case config.cookies[:secure] do
      :auto -> String.starts_with?(base_url || "", "https://")
      secure -> secure
    end
  end

  defp attributes(%Context{config: config} = ctx, cookie, max_age) do
    overrides = config.cookies[cookie] || []

    [
      http_only: true,
      secure: secure?(ctx),
      same_site: Keyword.get(overrides, :same_site, config.cookies[:same_site]),
      path: "/",
      domain: Keyword.get(overrides, :domain, config.cookies[:domain]),
      max_age: max_age
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
