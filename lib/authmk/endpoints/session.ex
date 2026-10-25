defmodule Authmk.Endpoints.Session do
  @moduledoc false
  # Session endpoints. See `Authmk.Endpoints`.

  alias Authmk.{CookieCache, Cookies, Input, Serializer, Sessions, SessionStore}

  def get_session(%{session: nil} = ctx), do: {:ok, nil, ctx}

  def get_session(ctx) do
    body = %{session: Serializer.session(ctx, ctx.session), user: Serializer.user(ctx, ctx.user)}
    body = if ctx.private[:needs_refresh], do: Map.put(body, :needs_refresh, true), else: body
    {:ok, ctx.config.auth.customize_session(body, ctx), ctx}
  end

  # Only extra session fields with `input: true`; core fields are never input.
  def update_session(ctx) do
    with {:ok, session} <- SessionStore.update(ctx, ctx.session, Input.attrs(ctx, :session)) do
      ctx = CookieCache.put(%{ctx | session: session}, Cookies.remember_me?(ctx))
      {:ok, %{session: Serializer.session(ctx, session)}, ctx}
    end
  end

  def sign_out(ctx) do
    with :ok <- delete_session(ctx) do
      {:ok, %{success: true}, Cookies.clear_session(ctx)}
    end
  end

  def list_sessions(ctx) do
    sessions = Sessions.list(ctx, ctx.user.id)
    {:ok, Enum.map(sessions, &Serializer.session(ctx, &1)), ctx}
  end

  def revoke_session(ctx) do
    Sessions.revoke(ctx, ctx.user.id, ctx.params.id)
    ctx = if ctx.params.id == to_string(ctx.session.id), do: Cookies.clear_session(ctx), else: ctx
    {:ok, %{status: true}, ctx}
  end

  def revoke_sessions(ctx) do
    Sessions.revoke_all(ctx, ctx.user.id)
    {:ok, %{status: true}, Cookies.clear_session(ctx)}
  end

  def revoke_other_sessions(ctx) do
    Sessions.revoke_others(ctx, ctx.user.id, ctx.session.id)
    {:ok, %{status: true}, ctx}
  end

  defp delete_session(%{session: nil}), do: :ok

  defp delete_session(ctx), do: SessionStore.delete(ctx, ctx.session)
end
