defmodule Authmk.Plug.RequireAbility do
  @moduledoc """
  Lets through only signed-in users with an ability, by
  `Authmk.Plugins.Gate`. Use after `Authmk.Plug.FetchSession`.

      # Anywhere in the app.
      plug Authmk.Plug.RequireAbility, auth: MyApp.Auth, ability: {:report, :view}

      # In the organization or team a path param names.
      plug Authmk.Plug.RequireAbility,
        auth: MyApp.Auth,
        ability: {:invoice, :view},
        resource: {:param, :organization, "organization_id"}

      # In the session's active organization.
      plug Authmk.Plug.RequireAbility,
        auth: MyApp.Auth,
        ability: {:invoice, :view},
        resource: :active_organization

  Path params only: a query string is too easy to change unnoticed. Use
  `resource: :active_organization` only on pages that show the active
  organization's data, and check each record with
  `Authmk.Plugins.Gate.allows?/4` before changing it.

  Signed-out requests get 401 and others 403, as JSON, or a redirect with
  `redirect_to:`.
  """

  @behaviour Plug

  alias Authmk.Error
  alias Authmk.Plug.Refusal
  alias Authmk.Plugins.Gate
  alias Authmk.Plugins.Gate.Page

  @impl true
  def init(opts) do
    %{
      auth: Keyword.fetch!(opts, :auth),
      ability: Keyword.fetch!(opts, :ability),
      resource: Page.validate!(opts[:resource]),
      redirect_to: opts[:redirect_to]
    }
  end

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, opts) when not is_nil(user) do
    resource = Page.resource(opts.resource, conn.path_params, conn.assigns[:current_session])

    if Gate.allows?(opts.auth, user, opts.ability, resource),
      do: conn,
      else: Refusal.refuse(conn, Error.new(:forbidden), opts.redirect_to)
  end

  def call(conn, opts), do: Refusal.refuse(conn, Error.new(:unauthorized), opts.redirect_to)
end
