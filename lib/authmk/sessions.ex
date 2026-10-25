defmodule Authmk.Sessions do
  @moduledoc """
  Creating, loading, refreshing and revoking sessions.

  A session expires `session[:expires_in]` seconds after it was last
  refreshed. A request refreshes it when more than `session[:update_age]`
  seconds have passed since the last refresh. A session is "fresh" for
  `session[:fresh_age]` seconds after sign-in; sensitive actions require that.
  """

  import Ecto.Query, only: [dynamic: 2]

  alias Authmk.{Context, Cookies, Error, Request, Store, Token}

  @doc """
  Creates a session for `user`, sets the cookie, and puts the session and
  user on the context.
  """
  @spec create(Context.t(), struct(), boolean()) :: {:ok, Context.t()} | {:error, Error.t()}
  def create(%Context{config: config} = ctx, user, remember_me \\ true) do
    token = Token.generate()
    track_ip = not config.advanced[:disable_ip_tracking]

    attrs = %{
      user_id: user.id,
      token: Token.hash(token),
      expires_at: expires_at(config),
      ip_address: if(track_ip, do: Request.client_ip(ctx)),
      user_agent: Request.user_agent(ctx)
    }

    with {:ok, session} <- Store.insert(ctx, :session, attrs) do
      ctx = Cookies.put_session(ctx, token, remember_me)
      {:ok, %{ctx | session: session, user: user}}
    end
  end

  @doc """
  Loads the session from the request cookie. Expired or unknown sessions
  clear the cookie. Puts `session` and `user` on the context (both `nil`
  when signed out).
  """
  @spec load(Context.t()) :: Context.t()
  def load(%Context{conn: conn, config: config} = ctx) do
    case conn.req_cookies[Cookies.session_name(config)] do
      nil -> ctx
      token -> load_token(ctx, token)
    end
  end

  defp load_token(ctx, token) do
    case Store.get_by(ctx, :session, token: Token.hash(token)) do
      nil ->
        Cookies.clear_session(ctx)

      session ->
        if expired?(session) do
          # Cleanup only: the session is rejected whether or not this works.
          _ = Store.delete(ctx, :session, session)
          Cookies.clear_session(ctx)
        else
          user = Store.get_by(ctx, :user, id: session.user_id)
          maybe_refresh(%{ctx | session: session, user: user}, token)
        end
    end
  end

  @doc "Whether the context's session was created within `session[:fresh_age]` seconds."
  @spec fresh?(Context.t()) :: boolean()
  def fresh?(%Context{session: session, config: config}) do
    fresh_age = config.session[:fresh_age]
    fresh_age == 0 or DateTime.diff(DateTime.utc_now(), session.inserted_at) < fresh_age
  end

  @doc "Active sessions of a user."
  @spec list(Context.t(), term()) :: [struct()]
  def list(ctx, user_id) do
    now = DateTime.utc_now()
    Store.all(ctx, :session, dynamic([s], s.user_id == ^user_id and s.expires_at > ^now))
  end

  @doc "Revokes one session of a user by id."
  @spec revoke(Context.t(), term(), term()) :: :ok
  def revoke(ctx, user_id, session_id) do
    Store.delete_all(ctx, :session, dynamic([s], s.user_id == ^user_id and s.id == ^session_id))
    :ok
  end

  @doc "Revokes every session of a user."
  @spec revoke_all(Context.t(), term()) :: :ok
  def revoke_all(ctx, user_id) do
    Store.delete_all(ctx, :session, user_id: user_id)
    :ok
  end

  @doc "Revokes every session of a user except `keep_id`."
  @spec revoke_others(Context.t(), term(), term()) :: :ok
  def revoke_others(ctx, user_id, keep_id) do
    Store.delete_all(ctx, :session, dynamic([s], s.user_id == ^user_id and s.id != ^keep_id))
    :ok
  end

  defp maybe_refresh(%Context{config: config, session: session} = ctx, token) do
    refreshed_at = DateTime.add(session.expires_at, -config.session[:expires_in])
    due? = DateTime.diff(DateTime.utc_now(), refreshed_at) >= config.session[:update_age]

    if due? and not config.session[:disable_refresh] do
      {:ok, session} = Store.update(ctx, :session, session, %{expires_at: expires_at(config)})
      Cookies.put_session(%{ctx | session: session}, token, Cookies.remember_me?(ctx))
    else
      ctx
    end
  end

  defp expired?(session), do: DateTime.before?(session.expires_at, DateTime.utc_now())

  defp expires_at(config), do: DateTime.add(DateTime.utc_now(), config.session[:expires_in])
end
