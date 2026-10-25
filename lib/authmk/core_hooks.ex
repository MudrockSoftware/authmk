defmodule Authmk.CoreHooks do
  @moduledoc false
  # authmk's own database hooks. They run like a plugin's, before every
  # plugin: cached sessions in secondary storage follow their user.

  alias Authmk.SessionStore

  def database_hook(:after_update, :user, user, ctx), do: SessionStore.refresh_user(ctx, user)
  def database_hook(:after_delete, :user, user, ctx), do: SessionStore.forget_user(ctx, user.id)
  def database_hook(_event, _model, data, _ctx), do: {:ok, data}
end
