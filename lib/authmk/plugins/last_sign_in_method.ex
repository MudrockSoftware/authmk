defmodule Authmk.Plugins.LastSignInMethod do
  @moduledoc """
  Remembers how a user last signed in, so sign-in pages can point at it
  ("You last used Google").

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.LastSignInMethod], ...

  Every sign-in that starts a session sets the `last_sign_in_method` cookie
  (named like the other cookies: `authmk.last_sign_in_method`). Browser
  scripts can read it: it isn't `HttpOnly`, and holds only the method's
  name. It follows the `cookies` config, so with a cookie `domain` every
  subdomain sees it. Read it on the server with `get/2`.

  Methods are `"email"`, `"username"`, `"phone-number"`, `"email-otp"`,
  `"magic-link"`, `"passkey"`, `"siwe"`, and the provider's id for social
  sign-in and One Tap (`"github"`, `"google"`). When a sign-in needs a
  second step (two-factor, a verified email first), the method of the first
  step is kept for a few minutes and recorded when the session starts.

  With `store_in_database: true`, the user's `last_sign_in_method` field
  holds it too, across devices.

  Under GDPR and similar rules, the cookie may need consent: pass
  `store_cookie: &MyApp.Consent.allowed?/2` (given the `Authmk.Context` and
  the method; `false` skips the cookie, and the sign-in goes on), or
  `store_cookie: false`.

  ## Options

    * `:max_age` - seconds the cookie lasts (default 30 days)
    * `:store_in_database` - add and keep the user field (default `false`)
    * `:store_cookie` - `true`, `false`, or a function deciding per sign-in
    * `:resolve_method` - `fn endpoint_name, ctx -> method | nil end`, for
      your own sign-in endpoints; `nil` falls back to the built-in names
  """

  use Authmk.Plugin

  alias Authmk.{BaseURL, Context, Cookies, Crypto, Log, SessionStore, Store, Token}

  @pending_max_age 600
  @method_format ~r/\A[a-zA-Z0-9_-]{1,64}\z/

  @methods %{
    sign_in_email: "email",
    sign_up_email: "email",
    sign_in_username: "username",
    sign_in_phone_number: "phone-number",
    sign_in_email_otp: "email-otp",
    magic_link_verify: "magic-link",
    passkey_verify_authentication: "passkey",
    siwe_verify: "siwe",
    one_tap_callback: "google",
    one_tap_redirect: "google"
  }

  @impl true
  def init(opts) do
    NimbleOptions.validate!(opts,
      max_age: [type: :pos_integer, default: 30 * 24 * 60 * 60],
      store_in_database: [type: :boolean, default: false],
      store_cookie: [type: {:or, [:boolean, {:fun, 2}]}, default: true],
      resolve_method: [type: {:fun, 2}]
    )
  end

  @impl true
  def schema(opts) do
    if opts[:store_in_database],
      do: %{user: [fields: [last_sign_in_method: [type: :string, input: false]]]},
      else: %{}
  end

  @impl true
  def after_endpoint(endpoint, ctx, {:ok, body, %Context{} = result_ctx}),
    do: {:ok, body, record(endpoint, ctx, result_ctx)}

  def after_endpoint(endpoint, ctx, {:redirect, url, %Context{} = result_ctx}),
    do: {:redirect, url, record(endpoint, ctx, result_ctx)}

  def after_endpoint(endpoint, ctx, {:json, status, body, %Context{} = result_ctx}),
    do: {:json, status, body, record(endpoint, ctx, result_ctx)}

  def after_endpoint(_endpoint, _ctx, result), do: result

  @doc """
  The method from the request's cookie, or `nil`. For server-rendered
  sign-in pages.
  """
  @spec get(Plug.Conn.t(), module()) :: String.t() | nil
  def get(%Plug.Conn{} = conn, auth) do
    config = auth.config()

    case BaseURL.resolve(config, conn) do
      {:ok, base_url} ->
        ctx = %Context{config: config, conn: Plug.Conn.fetch_cookies(conn), base_url: base_url}
        valid_method(Cookies.get(ctx, :last_sign_in_method))

      _unknown_host ->
        nil
    end
  end

  # A new session records the method; a sign-in still waiting for its
  # second step keeps it pending.
  defp record(endpoint, request_ctx, result_ctx) do
    case new_session(request_ctx, result_ctx) do
      nil ->
        remember_pending(result_ctx, resolve(endpoint, request_ctx))

      session ->
        store(result_ctx, session, resolve(endpoint, request_ctx) || pending(request_ctx))
    end
  end

  defp store(ctx, _session, nil), do: ctx

  defp store(ctx, session, method) do
    :ok = store_in_database(ctx, session, method)
    ctx = Cookies.delete(ctx, :pending_sign_in_method)

    if store_cookie?(ctx, method),
      do: Cookies.put(ctx, :last_sign_in_method, method, opts(ctx)[:max_age], http_only: false),
      else: ctx
  end

  defp remember_pending(ctx, nil), do: ctx

  defp remember_pending(ctx, method),
    do: Cookies.put(ctx, :pending_sign_in_method, method, @pending_max_age)

  defp pending(ctx), do: valid_method(Cookies.get(ctx, :pending_sign_in_method))

  defp store_in_database(ctx, session, method) do
    if opts(ctx)[:store_in_database] and session.user.last_sign_in_method != method do
      case Store.update(ctx, :user, session.user, %{last_sign_in_method: method}) do
        {:ok, _user} -> :ok
        # A hint isn't worth failing a sign-in over.
        {:error, error} -> Log.warning("authmk: last sign-in method not saved: #{error.code}")
      end
    end

    :ok
  end

  # The consent function failing means no consent.
  defp store_cookie?(ctx, method) do
    case opts(ctx)[:store_cookie] do
      allowed? when is_function(allowed?, 2) -> allowed?.(ctx, method) == true
      store_cookie -> store_cookie
    end
  rescue
    error ->
      Log.error("authmk: store_cookie raised #{inspect(error.__struct__)}")
      false
  end

  defp resolve(endpoint, ctx) do
    custom = opts(ctx)[:resolve_method]
    valid_method((custom && custom.(endpoint, ctx)) || built_in(endpoint, ctx))
  end

  defp built_in(endpoint, %Context{params: params})
       when endpoint in [:callback, :sign_in_social],
       do: params[:provider]

  defp built_in(endpoint, _ctx), do: @methods[endpoint]

  # The session this response started, if any: a session cookie with a
  # token the request didn't already have.
  defp new_session(request_ctx, %Context{resp_cookies: cookies, config: config} = ctx) do
    name = Cookies.name(ctx, :session_token)

    with {^name, signed, _opts} when is_binary(signed) <- List.keyfind(cookies, name, 0),
         {:ok, token} <- Crypto.verify(config, "session-token", signed),
         false <- Cookies.session_token(request_ctx) == {:ok, token},
         %{} = session <- SessionStore.fetch(ctx, Token.hash(token)) do
      session
    else
      _no_new_session -> nil
    end
  end

  defp valid_method(method) when is_binary(method) do
    if Regex.match?(@method_format, method), do: method
  end

  defp valid_method(_method), do: nil

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
