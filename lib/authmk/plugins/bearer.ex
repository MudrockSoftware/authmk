defmodule Authmk.Plugins.Bearer do
  @moduledoc """
  Bearer tokens: sessions for API and mobile clients that don't keep
  cookies.

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.Bearer], ...

  Whenever a response sets the session cookie (sign-in, refresh), it also
  carries the token in a `set-auth-token` header (exposed to browsers through
  `Access-Control-Expose-Headers`). Clients send it back as
  `Authorization: Bearer <token>`, and it works exactly like the cookie: in
  the auth router and in `Authmk.Plug.FetchSession`, with the same expiry,
  refreshes and revocation.

  The token is the signed session token, as in the cookie. With
  `require_signature: false`, the bare session token works too.

  ## Options

    * `:require_signature` - only accept signed tokens (default `true`)
  """

  use Authmk.Plugin

  alias Authmk.{Context, Cookies, Crypto, Error}

  @header "set-auth-token"

  @impl true
  def init(opts),
    do: NimbleOptions.validate!(opts, require_signature: [type: :boolean, default: true])

  @impl true
  def authenticate_request(%Context{conn: conn, config: config} = ctx) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" ->
        token(config, token, opts(ctx)[:require_signature])

      _no_bearer ->
        :none
    end
  end

  defp token(config, token, require_signature) do
    case Crypto.verify(config, "session-token", token) do
      {:ok, session_token} -> {:token, session_token}
      :error when require_signature -> {:error, Error.new(:unauthorized)}
      :error -> {:token, token}
    end
  end

  # The session cookie the response sets, as a header too.
  @impl true
  def on_response(conn, %Context{resp_cookies: cookies} = ctx) do
    name = Cookies.name(ctx, :session_token)

    case Enum.find(cookies, &match?({^name, value, _opts} when is_binary(value), &1)) do
      {^name, token, _opts} ->
        conn
        |> Plug.Conn.put_resp_header(@header, token)
        |> Plug.Conn.put_resp_header("access-control-expose-headers", @header)

      nil ->
        conn
    end
  end

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
