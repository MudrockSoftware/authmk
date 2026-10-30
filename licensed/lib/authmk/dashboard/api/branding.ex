defmodule Authmk.Dashboard.API.Branding do
  @moduledoc false
  # The Branding page (with Authmk.Dashboard.Branding): the app's name,
  # logo and colour. Changing them needs the Admin permission
  # `branding: update`.

  alias Authmk.Dashboard.Branding, as: Settings
  alias Authmk.Dashboard.{Data, Reply}

  def enabled?(ctx), do: Data.enabled?(ctx, Settings)

  @doc "What the dashboard itself shows: `nil` without the plugin."
  def public(ctx) do
    if enabled?(ctx), do: Settings.public(ctx, Settings.settings(ctx))
  end

  def route(conn, path, ctx, admin) do
    if enabled?(ctx),
      do: branding(conn, conn.method, path, ctx, admin),
      else: Reply.not_found(conn)
  end

  defp branding(conn, "GET", [], ctx, _admin) do
    Reply.json(conn, 200, %{
      branding: public(ctx),
      default_app_name: ctx.config.app_name
    })
  end

  defp branding(conn, "POST", [], ctx, admin) do
    changes = Reply.body(conn)
    event = {"branding.updated", %{metadata: %{changed: changes |> Map.keys() |> Enum.sort()}}}

    Reply.permitted(conn, ctx, admin, %{branding: [:update]}, event, fn ->
      with :ok <- Settings.update(ctx, changes), do: {:ok, %{branding: public(ctx)}}
    end)
  end

  defp branding(conn, _method, _path, _ctx, _admin), do: Reply.not_found(conn)
end
