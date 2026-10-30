defmodule Authmk.Plugins.Security.Events do
  @moduledoc false
  # Security events: telemetry, and the app's `on_event`.

  alias Authmk.{Log, Request}

  def emit(ctx, opts, type, details \\ %{}) do
    event = %{
      type: type,
      ip: ctx.conn && Request.client_ip(ctx),
      user_id: (ctx.user && ctx.user.id) || details[:user_id],
      details: Map.delete(details, :user_id)
    }

    :telemetry.execute([:authmk, :security, :event], %{}, Map.put(event, :auth, ctx.config.auth))

    if opts[:on_event] do
      try do
        opts[:on_event].(event, ctx)
      rescue
        exception -> Log.warning("security on_event failed: #{inspect(exception.__struct__)}")
      end
    end

    :ok
  end
end
