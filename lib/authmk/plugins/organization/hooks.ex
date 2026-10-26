defmodule Authmk.Plugins.Organization.Hooks do
  @moduledoc """
  Hooks on organization lifecycle events. Implement the ones you need and
  pass the module as the plugin's `hooks` option.

      defmodule MyApp.OrganizationHooks do
        @behaviour Authmk.Plugins.Organization.Hooks

        @impl true
        def before_event(:create_organization, attrs, _ctx), do: {:ok, Map.put(attrs, "logo", "/default.png")}
        def before_event(_event, data, _ctx), do: {:ok, data}

        @impl true
        def after_event(:add_member, member, _ctx), do: MyApp.Billing.seat_added(member)
        def after_event(_event, _record, _ctx), do: :ok
      end

  Events: `:create_organization`, `:update_organization`,
  `:delete_organization`, `:add_member`, `:remove_member`,
  `:update_member_role`, `:create_invitation`, `:accept_invitation`,
  `:reject_invitation`, `:cancel_invitation`, `:create_team`,
  `:update_team`, `:delete_team`, `:add_team_member`, `:remove_team_member`.

  `before_event/3` gets the attributes about to be written (or the record
  about to be deleted) and returns them, maybe changed, or
  `{:error, %Authmk.Error{}}` to stop. `after_event/3` gets the record.
  """

  alias Authmk.{Context, Error}
  alias Authmk.Plugins.Organization.Config

  @callback before_event(event :: atom(), data :: term(), Context.t()) ::
              {:ok, term()} | {:error, Error.t()}
  @callback after_event(event :: atom(), record :: term(), Context.t()) :: term()

  @optional_callbacks before_event: 3, after_event: 3

  @doc false
  def before_event(ctx, event, data) do
    case hooks(ctx) do
      nil ->
        {:ok, data}

      module ->
        if function_exported?(module, :before_event, 3),
          do: module.before_event(event, data, ctx),
          else: {:ok, data}
    end
  end

  @doc false
  def after_event(ctx, event, record) do
    module = hooks(ctx)

    if module && function_exported?(module, :after_event, 3),
      do: module.after_event(event, record, ctx)

    :ok
  end

  defp hooks(ctx) do
    module = Config.opts(ctx)[:hooks]
    if module, do: Code.ensure_loaded!(module)
    module
  end
end
