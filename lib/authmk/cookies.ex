defmodule Authmk.Cookies do
  @moduledoc """
  Session cookies.

  The session cookie holds the session token; the database only has its hash.
  It is `HttpOnly`, `SameSite=Lax` by default, and `Secure` with a
  `__Secure-` name prefix when the app runs on HTTPS.

  When a user signs in without "remember me", the session cookie has no
  `max-age` (the browser drops it on close) and a `dont_remember` marker
  cookie keeps it that way when the session is refreshed.
  """

  alias Authmk.{Config, Context}

  @doc "Name of the session cookie."
  @spec session_name(Config.t()) :: String.t()
  def session_name(config), do: name(config, "session_token")

  @doc "Name of the marker cookie for sessions without remember me."
  @spec dont_remember_name(Config.t()) :: String.t()
  def dont_remember_name(config), do: name(config, "dont_remember")

  @doc "Sets the session cookie."
  @spec put_session(Context.t(), String.t(), boolean()) :: Context.t()
  def put_session(%Context{config: config} = ctx, token, remember_me) do
    if remember_me do
      ctx
      |> Context.put_cookie(
        session_name(config),
        token,
        attributes(config, config.session[:expires_in])
      )
      |> Context.delete_cookie(dont_remember_name(config), attributes(config, nil))
    else
      ctx
      |> Context.put_cookie(session_name(config), token, attributes(config, nil))
      |> Context.put_cookie(dont_remember_name(config), "true", attributes(config, nil))
    end
  end

  @doc "Whether the current request's session was created without remember me."
  @spec remember_me?(Context.t()) :: boolean()
  def remember_me?(%Context{conn: conn, config: config}),
    do: conn.req_cookies[dont_remember_name(config)] != "true"

  @doc "Deletes the session cookies."
  @spec clear_session(Context.t()) :: Context.t()
  def clear_session(%Context{config: config} = ctx) do
    ctx
    |> Context.delete_cookie(session_name(config), attributes(config, nil))
    |> Context.delete_cookie(dont_remember_name(config), attributes(config, nil))
  end

  @doc "Whether cookies are marked `Secure`."
  @spec secure?(Config.t()) :: boolean()
  def secure?(config) do
    case config.cookies[:secure] do
      :auto -> String.starts_with?(config.base_url, "https://")
      secure -> secure
    end
  end

  defp name(config, suffix) do
    name = "#{config.cookies[:prefix]}.#{suffix}"
    if secure?(config), do: "__Secure-" <> name, else: name
  end

  defp attributes(config, max_age) do
    [
      http_only: true,
      secure: secure?(config),
      same_site: config.cookies[:same_site],
      path: "/",
      domain: config.cookies[:domain],
      max_age: max_age
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
