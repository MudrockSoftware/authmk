defmodule Authmk.Plugins.Organization do
  @moduledoc """
  Organizations: members with roles, invitations, an active organization
  per session, and optionally teams and roles each organization defines.

      use Authmk,
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.Organization, send_invitation_email: &MyApp.Auth.send_invitation/2}
        ],
        ...

  Whoever creates an organization joins it with `creator_role` (`owner`).
  What members may do comes from their role, through `access_control` (see
  `Authmk.Plugins.Organization.Permissions`). Only owners may give, change or
  take the owner role, and an organization always keeps one owner.

  Endpoints that act on an organization take `organization_id`, or use the
  session's active organization (`POST /organization/set-active`).

  | Method | Path | Permission |
  |---|---|---|
  | POST | `/organization/create` | (`allow_user_to_create_organization`) |
  | POST | `/organization/check-slug` | |
  | POST | `/organization/update` | `organization: update` |
  | POST | `/organization/delete` | `organization: delete` |
  | GET | `/organization/list` | |
  | GET | `/organization/get-full-organization` | member |
  | POST | `/organization/set-active` | member |
  | GET | `/organization/list-members` | member |
  | POST | `/organization/remove-member` | `member: delete` |
  | POST | `/organization/update-member-role` | `member: update` |
  | GET | `/organization/get-active-member` | member |
  | GET | `/organization/get-active-member-role` | member |
  | POST | `/organization/leave` | member |
  | POST | `/organization/invite-member` | `invitation: create` |
  | POST | `/organization/cancel-invitation` | `invitation: cancel` |
  | POST | `/organization/accept-invitation` | the invitee |
  | POST | `/organization/reject-invitation` | the invitee |
  | GET | `/organization/get-invitation` | the invitee |
  | GET | `/organization/list-invitations` | member |
  | GET | `/organization/list-user-invitations` | |
  | POST | `/organization/has-permission` | member |

  With `teams: [enabled: true]`: `/organization/create-team`,
  `/organization/update-team`, `/organization/remove-team`,
  `/organization/list-teams`, `/organization/set-active-team`,
  `/organization/list-user-teams`, `/organization/list-team-members`,
  `/organization/add-team-member` and `/organization/remove-team-member`.

  With `dynamic_access_control: [enabled: true]`, organizations define their
  own roles (`ac` permissions): `/organization/create-role`,
  `/organization/update-role`, `/organization/delete-role`,
  `/organization/list-roles` and `/organization/get-role`. A role grants
  only what the statements have, and only what its creator may do.

  Invitations go to an email with a role (and a team). Only that email's
  user may see, accept or reject one; accepting makes them a member and
  makes the organization active. Lifecycle hooks: see
  `Authmk.Plugins.Organization.Hooks`. Extra fields on `organization`,
  `member`, `invitation` and `team` come from the `schema:` option like any
  model's `additional_fields`.

  ## From server code

  Your own code (a back office, provisioning, an admin dashboard) manages
  organizations without being a member: `create_organization/3`,
  `update_organization/3`, `delete_organization/2`, `add_member/4`,
  `set_member_role/4`, `remove_member/3`, `invite_member/6`,
  `cancel_invitation/2`, and with teams `create_team/3`, `update_team/3`,
  `remove_team/2`, `add_team_member/3` and `remove_team_member/3`. They make
  the endpoints' checks, minus the signed-in member's own permissions, run
  the hooks, and keep an owner in every organization. They return
  `{:ok, record}` or `{:error, %Authmk.Error{}}`; ids that don't exist or
  aren't valid ids give the `*_not_found` errors.

      {:ok, organization} =
        Authmk.Plugins.Organization.create_organization(MyApp.Auth, %{name: "Acme", slug: "acme"}, user_id)

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.Organization.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{BaseURL, Context, Endpoint, Error, Input, Store}

  alias Authmk.Plugins.Organization.{
    Access,
    Invitations,
    Members,
    Options,
    Organizations,
    Roles,
    Teams
  }

  @impl true
  def init(opts) do
    opts = NimbleOptions.validate!(opts, Options.schema())
    access_control = opts[:access_control]

    unless Code.ensure_loaded?(access_control) and
             function_exported?(access_control, :access_control, 0) do
      raise ArgumentError, "#{inspect(access_control)} must `use Authmk.AccessControl`"
    end

    opts
  end

  @impl true
  def schema(opts) do
    teams = opts[:teams][:enabled] == true
    dynamic = opts[:dynamic_access_control][:enabled] == true

    %{
      organization: [
        plural: "organizations",
        fields: [
          name: [type: :string, required: true],
          slug: [type: :string, required: true, unique: true],
          logo: [type: :text],
          metadata: [type: :map]
        ]
      ],
      member: [
        plural: "members",
        fields: [
          organization_id: [
            references: :organization,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ],
          user_id: [
            references: :user,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ],
          role: [type: :string, required: true, input: false]
        ],
        indexes: [[columns: [:organization_id, :user_id], unique: true]]
      ],
      invitation: [
        plural: "invitations",
        fields:
          [
            organization_id: [
              references: :organization,
              on_delete: :delete_all,
              required: true,
              index: true,
              input: false
            ],
            email: [type: :string, required: true, index: true, input: false],
            role: [type: :string, required: true, input: false],
            status: [type: :string, required: true, default: "pending", input: false],
            expires_at: [type: :datetime, required: true, input: false],
            inviter_id: [references: :user, on_delete: :delete_all, required: true, input: false]
          ] ++
            if(teams,
              do: [team_id: [references: :team, on_delete: :nilify_all, input: false]],
              else: []
            )
      ],
      session: [
        fields:
          [active_organization_id: [type: :string, input: false]] ++
            if(teams, do: [active_team_id: [type: :string, input: false]], else: [])
      ]
    }
    |> Map.merge(if(teams, do: team_models(), else: %{}))
    |> Map.merge(if(dynamic, do: role_models(), else: %{}))
  end

  defp team_models do
    %{
      team: [
        plural: "teams",
        fields: [
          name: [type: :string, required: true],
          organization_id: [
            references: :organization,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ]
        ]
      ],
      team_member: [
        plural: "team_members",
        fields: [
          team_id: [
            references: :team,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ],
          user_id: [
            references: :user,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ]
        ],
        indexes: [[columns: [:team_id, :user_id], unique: true]]
      ]
    }
  end

  defp role_models do
    %{
      organization_role: [
        plural: "organization_roles",
        fields: [
          organization_id: [
            references: :organization,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ],
          role: [type: :string, required: true, input: false],
          # JSON: %{resource => [action]}
          permission: [type: :text, required: true, input: false]
        ],
        indexes: [[columns: [:organization_id, :role], unique: true]]
      ]
    }
  end

  @impl true
  def endpoints(opts) do
    core_endpoints() ++
      if(opts[:teams][:enabled], do: team_endpoints(), else: []) ++
      if(opts[:dynamic_access_control][:enabled], do: role_endpoints(), else: [])
  end

  defp core_endpoints do
    org_id = [organization_id: [type: :string]]

    [
      post(:create_organization, "/organization/create", {Organizations, :create},
        name: [type: :string, required: true],
        slug: [type: :string, required: true],
        keep_current_active_organization: [type: :boolean, default: false]
      ),
      post(:check_organization_slug, "/organization/check-slug", {Organizations, :check_slug},
        slug: [type: :string, required: true]
      ),
      post(
        :update_organization,
        "/organization/update",
        {Organizations, :update},
        org_id ++ [data: [type: :map, required: true]]
      ),
      post(:delete_organization, "/organization/delete", {Organizations, :delete},
        organization_id: [type: :string, required: true]
      ),
      get(:list_organizations, "/organization/list", {Organizations, :list}, []),
      get(
        :get_full_organization,
        "/organization/get-full-organization",
        {Organizations, :full},
        org_id ++ [organization_slug: [type: :string], members_limit: [type: :integer]]
      ),
      post(
        :set_active_organization,
        "/organization/set-active",
        {Organizations, :set_active},
        org_id ++ [organization_slug: [type: :string]]
      ),
      get(
        :list_members,
        "/organization/list-members",
        {Members, :list},
        org_id ++ [limit: [type: :integer], offset: [type: :integer]]
      ),
      post(
        :remove_member,
        "/organization/remove-member",
        {Members, :remove},
        org_id ++ [member_id_or_email: [type: :string, required: true]]
      ),
      post(
        :update_member_role,
        "/organization/update-member-role",
        {Members, :update_role},
        org_id ++
          [member_id: [type: :string, required: true], role: [type: :string, required: true]]
      ),
      get(:get_active_member, "/organization/get-active-member", {Members, :active_member}, []),
      get(
        :get_active_member_role,
        "/organization/get-active-member-role",
        {Members, :active_member_role},
        []
      ),
      post(:leave_organization, "/organization/leave", {Members, :leave},
        organization_id: [type: :string, required: true]
      ),
      post(
        :invite_member,
        "/organization/invite-member",
        {Invitations, :invite},
        org_id ++
          [
            email: [type: :string, required: true],
            role: [type: :string, required: true],
            resend: [type: :boolean, default: false],
            team_id: [type: :string]
          ]
      ),
      post(:cancel_invitation, "/organization/cancel-invitation", {Invitations, :cancel},
        invitation_id: [type: :string, required: true]
      ),
      post(:accept_invitation, "/organization/accept-invitation", {Invitations, :accept},
        invitation_id: [type: :string, required: true]
      ),
      post(:reject_invitation, "/organization/reject-invitation", {Invitations, :reject},
        invitation_id: [type: :string, required: true]
      ),
      get(:get_invitation, "/organization/get-invitation", {Invitations, :get},
        id: [type: :string, required: true]
      ),
      get(:list_invitations, "/organization/list-invitations", {Invitations, :list}, org_id),
      get(
        :list_user_invitations,
        "/organization/list-user-invitations",
        {Invitations, :list_for_user},
        []
      ),
      post(
        :organization_has_permission,
        "/organization/has-permission",
        {__MODULE__, :has_permission},
        org_id ++ [permissions: [type: :map, required: true]]
      )
    ]
  end

  defp team_endpoints do
    org_id = [organization_id: [type: :string]]
    team_id = [team_id: [type: :string, required: true]]

    [
      post(
        :create_team,
        "/organization/create-team",
        {Teams, :create},
        org_id ++ [name: [type: :string, required: true]]
      ),
      post(
        :update_team,
        "/organization/update-team",
        {Teams, :update},
        team_id ++ [data: [type: :map, required: true]]
      ),
      post(:remove_team, "/organization/remove-team", {Teams, :remove}, team_id),
      get(:list_teams, "/organization/list-teams", {Teams, :list}, org_id),
      post(:set_active_team, "/organization/set-active-team", {Teams, :set_active},
        team_id: [type: :string]
      ),
      get(:list_user_teams, "/organization/list-user-teams", {Teams, :list_for_user}, []),
      get(:list_team_members, "/organization/list-team-members", {Teams, :members},
        team_id: [type: :string]
      ),
      post(
        :add_team_member,
        "/organization/add-team-member",
        {Teams, :add_member},
        team_id ++ [user_id: [type: :string, required: true]]
      ),
      post(
        :remove_team_member,
        "/organization/remove-team-member",
        {Teams, :remove_member},
        team_id ++ [user_id: [type: :string, required: true]]
      )
    ]
  end

  defp role_endpoints do
    role = [organization_id: [type: :string], role: [type: :string, required: true]]

    [
      post(
        :create_organization_role,
        "/organization/create-role",
        {Roles, :create},
        role ++ [permission: [type: :map, required: true]]
      ),
      post(
        :update_organization_role,
        "/organization/update-role",
        {Roles, :update},
        role ++ [permission: [type: :map, required: true]]
      ),
      post(:delete_organization_role, "/organization/delete-role", {Roles, :delete}, role),
      get(:list_organization_roles, "/organization/list-roles", {Roles, :list},
        organization_id: [type: :string]
      ),
      get(:get_organization_role, "/organization/get-role", {Roles, :get}, role)
    ]
  end

  @doc false
  def has_permission(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, member} <- Access.member_of(ctx, id) do
      {:ok, %{success: Access.allowed?(ctx, organization, member.role, params.permissions)}, ctx}
    end
  end

  @doc """
  Creates an organization owned by the user `owner_user_id`, from your own
  server code (for example an admin dashboard). `attrs` takes `name` and
  `slug` (required), `logo`, `metadata` and the extra `organization` fields
  your app declares with `input: true`, with atom or string keys. The slug
  must be free; the owner joins with `creator_role`. Runs the
  `:create_organization` and `:add_member` hooks.

  It doesn't apply `allow_user_to_create_organization` or
  `organization_limit`: those limit what users do themselves, and here your
  server decides.

      Authmk.Plugins.Organization.create_organization(MyApp.Auth, %{name: "Acme", slug: "acme"}, user_id)
  """
  @spec create_organization(module(), map(), term()) ::
          {:ok, struct()} | {:error, Error.t()}
  def create_organization(auth, attrs, owner_user_id) do
    ctx = server_ctx(auth)

    with {:ok, owner} <- fetch_user(ctx, owner_user_id),
         {:ok, organization, _member} <-
           Organizations.insert(ctx, input(ctx, :organization, attrs), owner) do
      {:ok, organization}
    end
  end

  @doc """
  Updates an organization, from your own server code: the fields
  `create_organization/3` takes, all optional. A new slug must be free.
  Runs the `:update_organization` hooks.
  """
  @spec update_organization(module(), term(), map()) :: {:ok, struct()} | {:error, Error.t()}
  def update_organization(auth, organization_id, attrs) do
    with_organization(auth, organization_id, &Organizations.change(&1, &2, string_keys(attrs)))
  end

  @doc """
  Deletes an organization, from your own server code, with its members,
  invitations and teams. Runs the `:delete_organization` hooks.
  """
  @spec delete_organization(module(), term()) :: {:ok, struct()} | {:error, Error.t()}
  def delete_organization(auth, organization_id) do
    with_organization(auth, organization_id, &Organizations.remove/2)
  end

  @doc """
  Adds a user to an organization, from your own server code (for example
  when you provision accounts). Checks the membership limit and runs the
  `:add_member` hooks.

      Authmk.Plugins.Organization.add_member(MyApp.Auth, organization_id, user_id, "member")
  """
  @spec add_member(module(), term(), term(), String.t()) ::
          {:ok, struct()} | {:error, Error.t()}
  def add_member(auth, organization_id, user_id, role) do
    with_member(auth, organization_id, user_id, &Members.add(&1, &2, &3, role))
  end

  @doc """
  The organizations `user` is a member of, oldest first: for an
  organization switcher (`Authmk.Components.Account.organization_switcher/1`).
  """
  @spec list_for_user(module(), struct()) :: [struct()]
  def list_for_user(auth, user) do
    Organizations.user_organizations(server_ctx(auth), user)
  end

  @doc """
  Sets a member's role, from your own server code (for example when a
  directory changes someone's groups). The last owner can't be demoted.
  """
  @spec set_member_role(module(), term(), term(), String.t()) ::
          {:ok, struct()} | {:error, Error.t()}
  def set_member_role(auth, organization_id, user_id, role) do
    with_member(auth, organization_id, user_id, &Members.set_role(&1, &2, &3, role))
  end

  @doc "Removes a user from an organization, from your own server code. Not the last owner."
  @spec remove_member(module(), term(), term()) :: {:ok, struct()} | {:error, Error.t()}
  def remove_member(auth, organization_id, user_id) do
    with_member(auth, organization_id, user_id, &Members.remove_user/3)
  end

  @doc """
  Invites `email` to an organization with `role`, from your own server code,
  on behalf of the user `inviter_user_id`. The invite endpoint's checks
  apply, minus the inviter's own permissions: a valid email and role, not a
  member yet, the invitation limit, and one pending invitation per email.
  The invitation goes out through `send_invitation_email`, in the
  background.

  Options: `team_id:` (with teams enabled), and `resend: true` to send a
  pending invitation again with a new expiry.
  """
  @spec invite_member(module(), term(), String.t(), String.t(), term(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def invite_member(auth, organization_id, email, role, inviter_user_id, opts \\ []) do
    opts = Keyword.validate!(opts, [:team_id, resend: false])
    ctx = server_ctx(auth)

    with {:ok, organization} <- Access.fetch_organization(ctx, organization_id),
         {:ok, inviter} <- fetch_user(ctx, inviter_user_id) do
      Invitations.invite_from_server(ctx, organization, inviter, email, role, opts)
    end
  end

  @doc "Cancels a pending invitation, from your own server code. Runs the `:cancel_invitation` hooks."
  @spec cancel_invitation(module(), term()) :: {:ok, struct()} | {:error, Error.t()}
  def cancel_invitation(auth, invitation_id) do
    Invitations.cancel_from_server(server_ctx(auth), invitation_id)
  end

  @doc """
  Creates a team in an organization, from your own server code: `attrs`
  takes `name` and the extra `team` fields your app declares with
  `input: true`. `maximum_teams` applies. Runs the `:create_team` hooks.
  Needs `teams: [enabled: true]` (`feature_disabled` otherwise), like every
  team function.
  """
  @spec create_team(module(), term(), map()) :: {:ok, struct()} | {:error, Error.t()}
  def create_team(auth, organization_id, attrs) do
    ctx = server_ctx(auth)

    with :ok <- teams_enabled(ctx),
         {:ok, organization} <- Access.fetch_organization(ctx, organization_id) do
      Teams.insert(ctx, organization, input(ctx, :team, attrs))
    end
  end

  @doc "Updates a team, from your own server code. Runs the `:update_team` hooks."
  @spec update_team(module(), term(), map()) :: {:ok, struct()} | {:error, Error.t()}
  def update_team(auth, team_id, attrs) do
    with_team(auth, team_id, &Teams.change(&1, &2, string_keys(attrs)))
  end

  @doc """
  Deletes a team, from your own server code. With
  `allow_removing_all_teams: false`, an organization keeps its last team.
  Runs the `:delete_team` hooks.
  """
  @spec remove_team(module(), term()) :: {:ok, struct()} | {:error, Error.t()}
  def remove_team(auth, team_id) do
    with_team(auth, team_id, &Teams.delete/2)
  end

  @doc """
  Adds a member of the team's organization to the team, from your own
  server code. `maximum_members_per_team` applies. Runs the
  `:add_team_member` hooks.
  """
  @spec add_team_member(module(), term(), term()) :: {:ok, struct()} | {:error, Error.t()}
  def add_team_member(auth, team_id, user_id) do
    with_team(auth, team_id, &Teams.add_user(&1, &2, user_id))
  end

  @doc "Takes a user out of a team, from your own server code. Runs the `:remove_team_member` hooks."
  @spec remove_team_member(module(), term(), term()) :: {:ok, struct()} | {:error, Error.t()}
  def remove_team_member(auth, team_id, user_id) do
    with_team(auth, team_id, &Teams.remove_user(&1, &2, user_id))
  end

  # A context for calls from server code: no request, and the configured
  # base URL (when it's static) for links in invitations.
  defp server_ctx(auth) do
    config = auth.config()

    base_url =
      case BaseURL.resolve(config, nil) do
        {:ok, base_url} -> base_url
        _dynamic -> nil
      end

    %{Context.new(config) | base_url: base_url}
    |> Context.put_private(:organization_plugin, __MODULE__)
  end

  defp with_organization(auth, organization_id, fun) do
    ctx = server_ctx(auth)

    with {:ok, organization} <- Access.fetch_organization(ctx, organization_id) do
      fun.(ctx, organization)
    end
  end

  defp with_member(auth, organization_id, user_id, fun) do
    ctx = server_ctx(auth)

    with {:ok, organization} <- Access.fetch_organization(ctx, organization_id),
         {:ok, user} <- fetch_user(ctx, user_id) do
      fun.(ctx, organization, user)
    end
  end

  defp with_team(auth, team_id, fun) do
    ctx = server_ctx(auth)

    with :ok <- teams_enabled(ctx),
         {:ok, team} <- Teams.fetch(ctx, team_id) do
      fun.(ctx, team)
    end
  end

  defp teams_enabled(ctx) do
    if Context.plugin_opts(ctx, __MODULE__)[:teams][:enabled],
      do: :ok,
      else: {:error, Error.new(:feature_disabled)}
  end

  defp fetch_user(_ctx, nil), do: {:error, user_not_found()}

  defp fetch_user(ctx, id) do
    case Store.get_by(ctx, :user, id: id) do
      nil -> {:error, user_not_found()}
      user -> {:ok, user}
    end
  rescue
    Ecto.Query.CastError -> {:error, user_not_found()}
  end

  defp user_not_found, do: Error.custom(:user_not_found, 404, "User not found")

  # The fields of `model` a client may set, from `attrs` with atom or string keys.
  defp input(ctx, model, attrs), do: Input.attrs(%{ctx | raw_params: string_keys(attrs)}, model)

  defp string_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp post(name, path, handler, params), do: endpoint(name, :post, path, handler, params)
  defp get(name, path, handler, params), do: endpoint(name, :get, path, handler, params)

  defp endpoint(name, method, path, handler, params) do
    Endpoint.new(
      name: name,
      method: method,
      path: path,
      handler: handler,
      session: :required,
      params: params
    )
  end
end
