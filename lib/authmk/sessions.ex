defmodule Authmk.Sessions do
  @moduledoc """
  Creating, loading, refreshing and revoking sessions.

  A session expires `session[:expires_in]` seconds after it was last
  refreshed. A request refreshes it when more than `session[:update_age]`
  seconds have passed since the last refresh. A session is "fresh" for
  `session[:fresh_age]` seconds after sign-in; sensitive actions require that.
  """

  alias Authmk.{Context, CookieCache, Cookies, Error, Hooks, Request, SessionStore, Token}

  @doc """
  Signs `user` in: asks plugins whether another step is needed first (see
  `c:Authmk.Plugin.sign_in_challenge/3`), and creates the session when none
  is. Every sign-in method goes through here.
  """
  @spec sign_in(Context.t(), struct(), boolean()) ::
          {:ok, Context.t()} | {:challenge, map(), Context.t()} | {:error, Error.t()}
  def sign_in(ctx, user, remember_me \\ true) do
    case Hooks.sign_in_challenge(ctx, user, remember_me) do
      {:cont, ctx} -> create(ctx, user, remember_me)
      other -> other
    end
  end

  @doc """
  Creates a session for `user`, sets the cookie, and puts the session and
  user on the context. Sign-ins use `sign_in/3` instead; this is for the
  step that finishes one, like a second factor. `extra` sets more session
  fields, like a plugin's own or a shorter `expires_at`.
  """
  @spec create(Context.t(), struct(), boolean(), map()) ::
          {:ok, Context.t()} | {:error, Error.t()}
  def create(%Context{config: config} = ctx, user, remember_me \\ true, extra \\ %{}) do
    token = Token.generate()
    track_ip = not config.advanced[:disable_ip_tracking]

    attrs = %{
      user_id: user.id,
      token: Token.hash(token),
      expires_at: expires_at(config),
      ip_address: if(track_ip, do: Request.client_ip(ctx)),
      user_agent: Request.user_agent(ctx)
    }

    attrs = Map.merge(attrs, extra)

    with {:ok, session} <- SessionStore.insert(ctx, attrs, user) do
      ctx = %{Cookies.put_session(ctx, token, remember_me) | session: session, user: user}
      {:ok, CookieCache.put(ctx, remember_me)}
    end
  end

  @doc """
  Loads the session from the request cookie. Puts `session` and `user` on
  the context (both `nil` when signed out). Forged, expired or unknown
  sessions clear the cookies.

  Plugins may authenticate the request another way first (see
  `c:Authmk.Plugin.authenticate_request/1`). When one refuses it, the error
  is in `ctx.private.authentication_error`, and the request is signed out.
  When one authenticates something other than a user (a service account),
  it is in `ctx.private.principal`, with no session or user.

  With `cache: true` the cookie cache is used when enabled. Only read paths
  should pass it.
  """
  @spec load(Context.t(), keyword()) :: Context.t()
  def load(%Context{} = ctx, opts \\ []) do
    case Hooks.authenticate_request(ctx) do
      {:ok, session, user} ->
        %{ctx | session: session, user: user}

      {:principal, principal} ->
        %{Context.put_private(ctx, :principal, principal) | session: nil, user: nil}

      # A session token from elsewhere than the cookie: checked the same way.
      {:token, token} ->
        load_token(ctx, token)

      {:error, error} ->
        %{Context.put_private(ctx, :authentication_error, error) | session: nil, user: nil}

      :none ->
        load_from_cookie(ctx, opts)
    end
  end

  defp load_from_cookie(%Context{config: config} = ctx, opts) do
    use_cache = Keyword.get(opts, :cache, false) and CookieCache.enabled?(config)

    case Cookies.session_token(ctx) do
      :none -> drop_orphan_cache(ctx)
      :invalid -> Cookies.clear_session(ctx)
      {:ok, token} when use_cache -> load_cached(ctx, token)
      {:ok, token} -> load_token(ctx, token)
    end
  end

  defp load_cached(ctx, token) do
    case CookieCache.read(ctx, token) do
      {:ok, session, user} ->
        %{ctx | session: session, user: user}

      :miss ->
        load_token(ctx, token)
    end
  end

  defp load_token(ctx, token) do
    case SessionStore.fetch(ctx, Token.hash(token)) do
      nil ->
        Cookies.clear_session(ctx)

      session ->
        if expired?(session) do
          # Cleanup only: the session is rejected whether or not this works.
          :ok = SessionStore.delete(ctx, session)
          Cookies.clear_session(ctx)
        else
          %{ctx | session: session, user: session.user}
          |> maybe_refresh(token)
          |> refresh_cache()
        end
    end
  end

  defp refresh_cache(%Context{config: config} = ctx) do
    cond do
      CookieCache.enabled?(config) -> CookieCache.put(ctx, Cookies.remember_me?(ctx))
      Cookies.session_data(ctx) -> Cookies.delete(ctx, :session_data)
      true -> ctx
    end
  end

  # A cache cookie without a session cookie belongs to nobody.
  defp drop_orphan_cache(ctx) do
    if Cookies.session_data(ctx), do: Cookies.delete(ctx, :session_data), else: ctx
  end

  @doc """
  The live session with this token hash (its `user` loaded), or `nil` when
  it's gone or expired: for clients that keep the hash, not the cookie,
  like `Authmk.LiveView`. Every call reads the store, so revoked sessions
  stop working at once.
  """
  @spec fetch_by_token_hash(Context.t(), String.t()) :: struct() | nil
  def fetch_by_token_hash(ctx, token_hash) when is_binary(token_hash) do
    case SessionStore.fetch(ctx, token_hash) do
      nil -> nil
      session -> if expired?(session), do: nil, else: session
    end
  end

  def fetch_by_token_hash(_ctx, _token_hash), do: nil

  @doc "Whether the context's session was created within `session[:fresh_age]` seconds."
  @spec fresh?(Context.t()) :: boolean()
  def fresh?(%Context{session: session, config: config}) do
    fresh_age = config.session[:fresh_age]
    fresh_age == 0 or DateTime.diff(DateTime.utc_now(), session.inserted_at) < fresh_age
  end

  @doc "Active sessions of a user."
  @spec list(Context.t(), term()) :: [struct()]
  def list(ctx, user_id), do: SessionStore.list(ctx, user_id)

  @doc "Revokes one session of a user by id."
  @spec revoke(Context.t(), term(), term()) :: :ok
  def revoke(ctx, user_id, session_id), do: SessionStore.delete_by_id(ctx, user_id, session_id)

  @doc "Revokes every session of a user."
  @spec revoke_all(Context.t(), term()) :: :ok
  def revoke_all(ctx, user_id), do: SessionStore.delete_all(ctx, user_id)

  @doc "Revokes every session of a user except `keep_id`."
  @spec revoke_others(Context.t(), term(), term()) :: :ok
  def revoke_others(ctx, user_id, keep_id), do: SessionStore.delete_others(ctx, user_id, keep_id)

  defp maybe_refresh(%Context{config: config, session: session} = ctx, token) do
    refreshed_at = DateTime.add(session.expires_at, -config.session[:expires_in])
    due? = DateTime.diff(DateTime.utc_now(), refreshed_at) >= config.session[:update_age]

    cond do
      not due? or config.session[:disable_refresh] ->
        ctx

      # With defer_refresh, reads stay read-only and report that a refresh is due.
      config.session[:defer_refresh] and read_only?(ctx) ->
        Context.put_private(ctx, :needs_refresh, true)

      true ->
        refresh(ctx, token)
    end
  end

  defp refresh(%Context{config: config} = ctx, token) do
    case SessionStore.update(ctx, ctx.session, %{expires_at: expires_at(config)}) do
      {:ok, session} ->
        Cookies.put_session(%{ctx | session: session}, token, Cookies.remember_me?(ctx))

      # Best effort: the session is still valid without the refresh.
      {:error, _error} ->
        ctx
    end
  end

  defp read_only?(%Context{conn: conn}), do: conn.method in ["GET", "HEAD"]

  defp expired?(session), do: DateTime.before?(session.expires_at, DateTime.utc_now())

  defp expires_at(config), do: DateTime.add(DateTime.utc_now(), config.session[:expires_in])
end
