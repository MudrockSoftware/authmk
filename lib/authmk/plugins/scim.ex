defmodule Authmk.Plugins.SCIM do
  @moduledoc """
  SCIM 2.0 provisioning: your customers' directories (Okta, Entra ID,
  Google Workspace, JumpCloud...) create, update, deactivate and delete
  their people's accounts, and manage their groups.

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.Organization, {Authmk.Plugins.SCIM, can_manage: &MyApp.Auth.org_admin?/3}], ...

  Each directory gets a connection, usually one per organization, with its
  own bearer token (`POST /scim/connections`, or `create_connection/3`).
  The directory is configured with `<base URL>/scim/v2` and that token.

  | Method | Path |
  |---|---|
  | GET | `/scim/v2/ServiceProviderConfig`, `/scim/v2/ResourceTypes`, `/scim/v2/Schemas` |
  | GET, POST | `/scim/v2/Users` |
  | GET, PUT, PATCH, DELETE | `/scim/v2/Users/:id` |
  | GET, POST | `/scim/v2/Groups` |
  | GET, PUT, PATCH, DELETE | `/scim/v2/Groups/:id` |
  | POST | `/scim/connections`, `/scim/connections/rotate-token`, `/scim/connections/decommission` (session) |
  | GET | `/scim/connections` (session) |

  Lists take `filter` (`eq`, `ne`, `co`, `sw`, `ew`, `pr`, with `and`,
  `or` and parentheses), `startIndex` and `count`. PATCH takes the forms
  Okta and Entra ID send.

  A connection only sees what it provisioned. Users it deactivates
  (`active: false`) keep their account but can't sign in, and their
  sessions end; `DELETE` does the same, or deletes the user with
  `on_delete: :delete`. A provisioned email that already has an account is
  refused (`uniqueness`), unless `link_existing_users` or `resolve_user`
  say otherwise. With `Authmk.Plugins.Organization`, users join the
  connection's organization, and `group_roles` turns groups into roles.

  A connection may name an `Authmk.Plugins.SSO` provider (`provider_id`):
  the users it provisioned then sign in through that provider, which may
  link to them without owning their email domain.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.SCIM.Options.schema())}
  """

  use Authmk.Plugin

  import Ecto.Query

  alias Authmk.{Context, Endpoint, Error, Store}
  alias Authmk.Plugins.SCIM.{API, Connections, Management, Options}

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def schema(_opts) do
    %{
      scim_connection: [
        plural: "scim_connections",
        fields: [
          name: [type: :string, input: false],
          # Without foreign keys: those plugins may not be on.
          organization_id: [type: :string, index: true, input: false],
          provider_id: [type: :string, input: false],
          user_id: [references: :user, index: true, input: false],
          # SHA-256 of the bearer token.
          token: [
            type: :string,
            required: true,
            unique: true,
            returned: false,
            redact: true,
            input: false
          ],
          status: [type: :string, required: true, default: "active", input: false],
          last_used_at: [type: :datetime, input: false]
        ]
      ],
      scim_user: [
        plural: "scim_users",
        fields: [
          scim_connection_id: [
            references: :scim_connection,
            on_delete: :delete_all,
            index: true,
            input: false
          ],
          user_id: [references: :user, on_delete: :delete_all, index: true, input: false],
          user_name: [type: :string, required: true, index: true, input: false],
          external_id: [type: :string, index: true, input: false],
          given_name: [type: :string, input: false],
          family_name: [type: :string, input: false],
          active: [type: :boolean, required: true, default: true, input: false],
          deprovisioned_at: [type: :datetime, input: false]
        ]
      ],
      scim_group: [
        plural: "scim_groups",
        fields: [
          scim_connection_id: [
            references: :scim_connection,
            on_delete: :delete_all,
            index: true,
            input: false
          ],
          display_name: [type: :string, required: true, input: false],
          external_id: [type: :string, input: false],
          role: [type: :string, input: false]
        ]
      ],
      scim_group_member: [
        plural: "scim_group_members",
        fields: [
          scim_group_id: [
            references: :scim_group,
            on_delete: :delete_all,
            index: true,
            input: false
          ],
          scim_user_id: [
            references: :scim_user,
            on_delete: :delete_all,
            index: true,
            input: false
          ]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    resource_routes(
      "Users",
      :list_users,
      :create_user,
      :get_user,
      :replace_user,
      :patch_user,
      :delete_user
    ) ++
      resource_routes(
        "Groups",
        :list_groups,
        :create_group,
        :get_group,
        :replace_group,
        :patch_group,
        :delete_group
      ) ++
      [
        scim(
          :scim_service_provider_config,
          :get,
          "/scim/v2/ServiceProviderConfig",
          :service_provider_config
        ),
        scim(:resource_types, :get, "/scim/v2/ResourceTypes", :resource_types),
        scim(:schemas, :get, "/scim/v2/Schemas", :schemas),
        manage(:scim_create_connection, :post, "/scim/connections", :create,
          organization_id: [type: :string, required: true],
          provider_id: [type: :string],
          name: [type: :string]
        ),
        manage(:scim_list_connections, :get, "/scim/connections", :list,
          organization_id: [type: :string, required: true]
        ),
        manage(:scim_rotate_token, :post, "/scim/connections/rotate-token", :rotate,
          connection_id: [type: :string, required: true]
        ),
        manage(:scim_decommission, :post, "/scim/connections/decommission", :decommission,
          connection_id: [type: :string, required: true]
        )
      ]
  end

  defp resource_routes(resource, list, create, get, replace, patch, delete) do
    base = "/scim/v2/" <> resource

    [
      scim(list, :get, base, list),
      scim(create, :post, base, create),
      scim(get, :get, base <> "/:id", get),
      scim(replace, :put, base <> "/:id", replace),
      scim(patch, :patch, base <> "/:id", patch),
      scim(delete, :delete, base <> "/:id", delete)
    ]
  end

  # Directories call with a bearer token, never cookies: no CSRF to stop.
  defp scim(name, method, path, function) do
    name = :"scim_#{name}"

    Endpoint.new(
      name: name,
      method: method,
      path: path,
      handler: {API, function},
      origin_check: false,
      rate_limit: [window: 60, max: 600]
    )
  end

  defp manage(name, method, path, function, params),
    do:
      Endpoint.new(
        name: name,
        method: method,
        path: path,
        handler: {Management, function},
        session: :required,
        params: params
      )

  # Deactivated and deprovisioned users can't start sessions, however they
  # sign in.
  @impl true
  def database_hook(:before_create, :session, attrs, ctx) do
    inactive =
      from(l in Store.module(ctx, :scim_user),
        where: l.user_id == ^attrs.user_id and l.active == false
      )

    if Store.count(ctx, :scim_user, inactive) > 0,
      do:
        {:error,
         Error.custom(
           :account_deactivated,
           403,
           "This account was deactivated by your organization"
         )},
      else: {:ok, attrs}
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  @doc """
  Creates a connection from server code: `organization_id:`, and optionally
  `provider_id:` (an SSO provider) and `name:`. Returns it with its `token`,
  which is never shown again.
  """
  @spec create_connection(module(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create_connection(auth, attrs) do
    ctx = auth.config() |> Context.new() |> Context.put_private(:scim_plugin, __MODULE__)

    with {:ok, connection, token} <- Connections.create(ctx, Map.new(attrs)),
         do: {:ok, Map.put(Connections.to_public(connection), :token, token)}
  end

  @doc false
  # For Authmk.Plugins.SSO: whether a connection tied to the SSO provider
  # provisioned this user, so the provider may sign them in.
  @spec provisioned_for?(Context.t(), struct(), String.t()) :: boolean()
  def provisioned_for?(ctx, user, provider_id) do
    query =
      from(l in Store.module(ctx, :scim_user),
        join: c in ^Store.module(ctx, :scim_connection),
        on: c.id == l.scim_connection_id,
        where:
          l.user_id == ^user.id and c.provider_id == ^provider_id and c.status == "active" and
            l.active
      )

    Store.count(ctx, :scim_user, query) > 0
  end
end
