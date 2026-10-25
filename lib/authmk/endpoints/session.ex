defmodule Authmk.Endpoints.Session do
  @moduledoc false
  # Session endpoints. See `Authmk.Endpoints`.

  alias Authmk.{Cookies, Serializer, Sessions, Store}

  def get_session(%{session: nil} = ctx), do: {:ok, nil, ctx}

  def get_session(ctx) do
    body = %{session: Serializer.session(ctx, ctx.session), user: Serializer.user(ctx, ctx.user)}
    {:ok, body, ctx}
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

  defp delete_session(ctx) do
    with {:ok, _session} <- Store.delete(ctx, :session, ctx.session), do: :ok
  end
end
