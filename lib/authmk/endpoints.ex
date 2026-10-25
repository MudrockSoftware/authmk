defmodule Authmk.Endpoints do
  @moduledoc """
  Core endpoints, available in every auth module. Plugins add more.

  | Method | Path | Session |
  |---|---|---|
  | GET | `/ok` | none |
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
  """

  alias Authmk.Endpoint
  alias Authmk.Endpoints.{EmailVerification, Session, User}

  @strict [window: 10, max: 3]

  @doc "All core endpoints."
  @spec all() :: [Endpoint.t()]
  def all do
    [
      new(:ok, :get, "/ok", {__MODULE__, :ok}),
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
        params: [id: [type: :string, required: true]]
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
      new(:verify_email, :get, "/verify-email", {EmailVerification, :verify},
        session: :optional,
        params: [token: [type: :string, required: true], callback_url: [type: :string]]
      )
    ]
  end

  @doc false
  def ok(ctx), do: {:ok, %{ok: true}, ctx}

  defp new(name, method, path, handler, opts \\ []) do
    Endpoint.new([name: name, method: method, path: path, handler: handler] ++ opts)
  end
end
