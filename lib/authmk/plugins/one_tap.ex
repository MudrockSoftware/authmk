defmodule Authmk.Plugins.OneTap do
  @moduledoc """
  Google One Tap: sign in with the ID token Google's prompt gives.

      use Authmk,
        social_providers: [google: [client_id: "...", client_secret: "..."]],
        plugins: [{Authmk.Plugins.OneTap, redirect_url: "/dashboard"}],
        ...

  It uses the `google` social provider: tokens must be signed by Google and
  issued to its `client_id`, and users are created and linked by the same
  rules as social sign-in (see the social sign-in guide).

  | Method | Path | Session |
  |---|---|---|
  | POST | `/one-tap/callback` | none |
  | POST | `/one-tap/redirect` | none |

  In JavaScript (popup) mode, the page's callback sends Google's credential
  as `id_token` to `POST /one-tap/callback`, and gets the user back as JSON.

  In redirect mode, set Google's `data-login_uri` to
  `<base_url>/auth/one-tap/redirect`. Google posts the credential there from
  its own origin, so instead of authmk's origin check this endpoint takes
  Google's double-submit token (the `g_csrf_token` cookie and field must
  match) and accepts no `Origin` other than `https://accounts.google.com`.
  It redirects to `redirect_url`, or to the error page with `?error=<code>`.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.OneTap.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{Context, Endpoint, Error, URL}
  alias Authmk.Endpoints.Social
  alias Authmk.Plugins.OneTap.Options

  @google_origin "https://accounts.google.com"

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def endpoints(_opts) do
    [
      Endpoint.new(
        name: :one_tap_callback,
        method: :post,
        path: "/one-tap/callback",
        handler: {__MODULE__, :callback},
        rate_limit: [window: 10, max: 5],
        params: [
          id_token: [type: :string, required: true],
          request_sign_up: [type: :boolean, default: false]
        ]
      ),
      Endpoint.new(
        name: :one_tap_redirect,
        method: :post,
        path: "/one-tap/redirect",
        handler: {__MODULE__, :redirect},
        # Google posts from its own origin; the double-submit token stands in.
        origin_check: false,
        rate_limit: [window: 10, max: 5],
        params: [credential: [type: :string], g_csrf_token: [type: :string]]
      )
    ]
  end

  @doc false
  def callback(%Context{params: params} = ctx),
    do: Social.id_token_sign_in(ctx, :google, params.id_token)

  @doc false
  def redirect(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- from_google(ctx),
         :ok <- double_submitted(ctx),
         {:ok, body, ctx} <- Social.id_token_sign_in(ctx, :google, params.credential) do
      case body do
        %{user: _signed_in} -> {:redirect, opts[:redirect_url], ctx}
        %{redirect_url: url} when is_binary(url) -> {:redirect, url, ctx}
        _challenge -> fail(ctx, opts, Error.new(:additional_verification_required))
      end
    else
      {:error, error} -> fail(ctx, opts, error)
    end
  end

  defp from_google(%Context{conn: conn}) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] -> :ok
      [@google_origin] -> :ok
      _other -> {:error, Error.new(:invalid_origin)}
    end
  end

  # Google sets the cookie and posts the same value; a forged form can't read the cookie.
  defp double_submitted(%Context{conn: conn, params: params}) do
    cookie = conn.req_cookies["g_csrf_token"]
    field = params.g_csrf_token

    if is_binary(cookie) and is_binary(field) and cookie != "" and
         Plug.Crypto.secure_compare(cookie, field),
       do: :ok,
       else: {:error, Error.new(:invalid_origin)}
  end

  defp fail(%Context{config: config} = ctx, opts, error) do
    url = opts[:error_url] || config.errors[:error_url] || URL.endpoint(ctx, "/error")
    {:redirect, URL.append_query(url, error: error.code), ctx}
  end
end
