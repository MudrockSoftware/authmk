defmodule Authmk.Endpoints do
  @moduledoc """
  Core endpoints, available in every auth module. Plugins add more.

  | Method | Path | Session |
  |---|---|---|
  | GET | `/ok` | none |
  | GET | `/error` | none (HTML page for redirect flows) |
  | GET | `/get-session` | optional (may use the cookie cache) |
  | POST | `/get-session` | optional (refreshes a deferred session) |
  | POST | `/update-session` | required |
  | POST | `/sign-out` | optional |
  | GET | `/list-sessions` | required |
  | POST | `/revoke-session` | required |
  | POST | `/revoke-sessions` | required |
  | POST | `/revoke-other-sessions` | required |
  | POST | `/update-user` | required |
  | POST | `/change-email` | required |
  | GET | `/change-email/confirm` | none |
  | POST | `/delete-user` | required |
  | GET | `/delete-user/callback` | required |
  | GET | `/list-accounts` | required |
  | POST | `/send-verification-email` | optional |
  | GET | `/verify-email` | optional |
  | POST | `/sign-in/social` | none |
  | GET, POST | `/callback/:provider` | none |
  | GET | `/sign-in/initiate/:provider` | none (sign-in started by the provider) |
  | POST | `/sign-out/social` | required (also at the provider) |
  | POST | `/link-social` | required |
  | POST | `/unlink-account` | required |
  | POST | `/get-access-token` | required |
  | POST | `/refresh-token` | required |
  | GET | `/account-info` | required |
  """

  alias Authmk.{Branding, Context, Endpoint, Error, Log, Pages}
  alias Authmk.Endpoints.{EmailVerification, Session, Social, User}

  @strict [window: 10, max: 3]

  @doc "All core endpoints."
  @spec all() :: [Endpoint.t()]
  def all do
    [
      new(:ok, :get, "/ok", {__MODULE__, :ok}),
      new(:error_page, :get, "/error", {__MODULE__, :error_page},
        params: [error: [type: :string], error_description: [type: :string]]
      ),
      new(:get_session, :get, "/get-session", {Session, :get_session},
        session: :optional,
        cookie_cache: true,
        params: [disable_cookie_cache: [type: :boolean, default: false]]
      ),
      new(:refresh_session, :post, "/get-session", {Session, :get_session}, session: :optional),
      new(:update_session, :post, "/update-session", {Session, :update_session},
        session: :required
      ),
      new(:sign_out, :post, "/sign-out", {Session, :sign_out}, session: :optional),
      new(:list_sessions, :get, "/list-sessions", {Session, :list_sessions}, session: :required),
      new(:revoke_session, :post, "/revoke-session", {Session, :revoke_session},
        session: :required,
        params: [id: [type: :string], session_id: [type: :string]]
      ),
      new(:revoke_sessions, :post, "/revoke-sessions", {Session, :revoke_sessions},
        session: :required
      ),
      new(
        :revoke_other_sessions,
        :post,
        "/revoke-other-sessions",
        {Session, :revoke_other_sessions},
        session: :required
      ),
      new(:update_user, :post, "/update-user", {User, :update_user}, session: :required),
      new(:change_email, :post, "/change-email", {User, :change_email},
        session: :required,
        rate_limit: @strict,
        params: [new_email: [type: :string, required: true], callback_url: [type: :string]]
      ),
      new(:confirm_email_change, :get, "/change-email/confirm", {User, :confirm_email_change},
        params: [token: [type: :string, required: true], callback_url: [type: :string]]
      ),
      new(:delete_user, :post, "/delete-user", {User, :delete_user},
        session: :required,
        rate_limit: @strict,
        params: [password: [type: :string], callback_url: [type: :string]]
      ),
      new(:delete_user_callback, :get, "/delete-user/callback", {User, :delete_user_callback},
        session: :required,
        params: [token: [type: :string, required: true], callback_url: [type: :string]]
      ),
      new(:list_accounts, :get, "/list-accounts", {User, :list_accounts}, session: :required),
      new(:send_verification_email, :post, "/send-verification-email", {EmailVerification, :send},
        session: :optional,
        rate_limit: @strict,
        params: [email: [type: :string], callback_url: [type: :string]]
      ),
      new(:sign_in_social, :post, "/sign-in/social", {Social, :sign_in},
        session: :none,
        rate_limit: @strict,
        params: [
          provider: [type: :string, required: true],
          callback_url: [type: :string],
          new_user_callback_url: [type: :string],
          error_callback_url: [type: :string],
          disable_redirect: [type: :boolean, default: false],
          scopes: [type: {:array, :string}, default: []],
          login_hint: [type: :string],
          request_sign_up: [type: :boolean, default: false],
          id_token: [type: :map],
          additional_data: [type: :map]
        ]
      ),
      new(:callback, :get, "/callback/:provider", {Social, :callback},
        params: [
          provider: [type: :string, required: true],
          code: [type: :string],
          state: [type: :string],
          error: [type: :string],
          device_id: [type: :string]
        ]
      ),
      # Providers post here cross-site; it only redirects to the GET callback.
      new(:callback_post, :post, "/callback/:provider", {Social, :callback_post},
        origin_check: false
      ),
      new(:initiate_sign_in, :get, "/sign-in/initiate/:provider", {Social, :initiate},
        session: :none,
        rate_limit: @strict,
        params: [
          provider: [type: :string, required: true],
          iss: [type: :string],
          login_hint: [type: :string],
          target_link_uri: [type: :string]
        ]
      ),
      new(:sign_out_social, :post, "/sign-out/social", {Social, :sign_out},
        session: :required,
        params: [provider: [type: :string, required: true], callback_url: [type: :string]]
      ),
      new(:link_social, :post, "/link-social", {Social, :link},
        session: :required,
        params: [
          provider: [type: :string, required: true],
          callback_url: [type: :string],
          error_callback_url: [type: :string],
          disable_redirect: [type: :boolean, default: false],
          scopes: [type: {:array, :string}, default: []],
          additional_data: [type: :map]
        ]
      ),
      new(:unlink_account, :post, "/unlink-account", {Social, :unlink},
        session: :required,
        params: [provider_id: [type: :string, required: true], account_id: [type: :string]]
      ),
      new(:get_access_token, :post, "/get-access-token", {Social, :access_token},
        session: :required,
        params: [provider_id: [type: :string, required: true], account_id: [type: :string]]
      ),
      new(:refresh_token, :post, "/refresh-token", {Social, :refresh_token},
        session: :required,
        params: [provider_id: [type: :string, required: true], account_id: [type: :string]]
      ),
      new(:account_info, :get, "/account-info", {Social, :account_info},
        session: :required,
        params: [account_id: [type: :string, required: true]]
      ),
      new(:verify_email, :get, "/verify-email", {EmailVerification, :verify},
        session: :optional,
        params: [token: [type: :string, required: true], callback_url: [type: :string]]
      )
    ]
  end

  @doc false
  def ok(ctx), do: {:ok, %{ok: true}, ctx}

  @doc false
  # A plain page for errors in redirect flows. Everything shown is escaped.
  def error_page(%{params: params} = ctx) do
    code = params.error || "unknown_error"
    message = params.error_description || error_message(code)
    data = error_page_data(ctx, code, message)

    {:html, 400, error_page_html(ctx, data), page_headers(ctx)}
  end

  defp error_message(code) do
    case Enum.find(Error.codes(), fn {known, _} -> Atom.to_string(known) == code end) do
      {_code, {_status, text}} -> text
      nil -> "Something went wrong while signing you in."
    end
  end

  defp error_page_data(ctx, code, message) do
    branding = Branding.get(ctx)

    %{
      code: code,
      message: message,
      app_name: branding.app_name,
      home: "/",
      logo_url: Branding.page_logo_url(branding, ctx),
      primary_color: branding.primary_color,
      primary_content_color: branding.primary_content_color
    }
  end

  defp error_page_html(ctx, data) do
    with :default <- custom_error_page(ctx.config.errors[:page], data, ctx),
         :missing <- Pages.render("error", data) do
      render_error_page(data.code, data.message)
    else
      {:ok, html} -> html
    end
  end

  # The app's own template (`errors: [page: {module, function}]`). If it
  # fails, people still get a page: authmk's.
  defp custom_error_page(nil, _data, _ctx), do: :default

  defp custom_error_page({module, function}, data, ctx) do
    {:ok, IO.iodata_to_binary(apply(module, function, [data, ctx]))}
  rescue
    exception ->
      Log.error(
        "authmk error page: #{inspect(module)}.#{function}/2 failed " <>
          "(#{inspect(exception.__struct__)}); serving authmk's page"
      )

      :default
  end

  # Only this site may frame it, which no one should.
  defp page_headers(ctx) do
    ctx
    |> Context.put_resp_header("x-frame-options", "DENY")
    |> Context.put_resp_header("content-security-policy", "frame-ancestors 'none'")
    |> Context.put_resp_header("referrer-policy", "no-referrer")
  end

  # Without the built pages (priv/pages): plain, but still a page.
  defp render_error_page(code, message) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head><meta charset="utf-8"><title>Sign-in error</title>
      <style>body{font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem}code{color:#b91c1c}</style></head>
      <body>
        <h1>Sign-in error</h1>
        <p>#{escape(message)}</p>
        <p>Code: <code>#{escape(code)}</code></p>
      </body>
    </html>
    """
  end

  defp escape(text), do: text |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()

  defp new(name, method, path, handler, opts \\ []) do
    Endpoint.new([name: name, method: method, path: path, handler: handler] ++ opts)
  end
end
