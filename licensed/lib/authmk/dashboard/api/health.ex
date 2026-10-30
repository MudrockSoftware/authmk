defmodule Authmk.Dashboard.API.Health do
  @moduledoc false
  # Health checks (Authmk.Dashboard.Health). `?network=true` also asks the
  # providers, which takes a few seconds: the Integrations page does, the
  # home page's warnings don't.

  alias Authmk.Dashboard.{Health, Reply}

  def route(%Plug.Conn{method: "GET"} = conn, [], ctx, _admin) do
    network = Reply.param(conn, "network") == "true"
    Reply.json(conn, 200, %{checks: Health.checks(ctx, network: network), network: network})
  end

  def route(conn, _path, _ctx, _admin), do: Reply.not_found(conn)
end
