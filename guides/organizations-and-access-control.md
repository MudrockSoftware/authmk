# Organizations and access control

One building block, `Authmk.AccessControl`, decides who may do what for
four plugins: Admin for your staff, Organization for your customers' teams,
API keys for programs acting for someone, and service accounts for programs
acting on their own.

## Roles and permissions

Statements list your resources and the actions on them. Roles grant some
of those actions:

```elixir
defmodule MyApp.Permissions do
  use Authmk.AccessControl,
    statements: [project: [:create, :update, :delete], billing: [:read, :update]],
    roles: [
      owner: [project: [:create, :update, :delete], billing: [:read, :update]],
      member: [project: [:create, :update]],
      viewer: []
    ]
end

MyApp.Permissions.has_permission?("member", %{project: [:create]})       #=> true
MyApp.Permissions.has_permission?("viewer,member", %{billing: [:read]})  #=> false
MyApp.Permissions.has_permission?("member", %{project: [:delete, :create]}, :or)  #=> true
```

Every action asked for must be granted, by any of the roles. With `:or`,
one is enough. Asking for nothing is `false`. Roles come as a list or a
comma-separated string, which is how users and members store them. Roles
that don't exist grant nothing, and a role that names an action no
statement has fails at compile time. Checks make no database call.

## Admins

Add `Authmk.Plugins.Admin` to your `plugins:`. It gives users a `role`
(`"user"` by default) and lets admins manage other users. Run
`mix authmk.gen.migration` and `mix ecto.migrate`, then create the first
admin:

```sh
AUTHMK_ADMIN_PASSWORD=... mix authmk.create_admin ada@example.com --name "Ada Lovelace"
```

The password comes from the environment, never the command line. Without
it, the admin sets one with a password reset. An existing user keeps their
password and gets the admin role next to their own. Add `--auth MyApp.Auth`
when the app has several auth modules. In a release, call
`Authmk.Plugins.Admin.create_admin(MyApp.Auth, email: "ada@example.com")`.

### Managing users

Each `/auth/admin/*` endpoint needs a signed-in user whose role grants the
action, or who is in `admin_user_ids`. With the default
`Authmk.Plugins.Admin.Permissions`, the `admin` role may do everything
except impersonate other admins, and `user` may do nothing.

| Endpoint | Permission |
| --- | --- |
| `POST create-user`, `GET list-users`, `GET get-user`, `POST update-user` | `user: create`, `list`, `get`, `update` |
| `POST set-role`, `POST set-user-password`, `POST remove-user` | `user: set_role`, `set_password`, `delete` |
| `POST ban-user`, `POST unban-user` | `user: ban` |
| `POST impersonate-user` | `user: impersonate` |
| `POST list-user-sessions`, `revoke-user-session`, `revoke-user-sessions` | `session: list`, `revoke` |

`list-users` answers `{"users": [...], "total": 42, "limit": 20, "offset": 0}`.
It takes `search_value`, `search_field` (`email` or `name`),
`search_operator` (`contains`, `starts_with`, `ends_with`), `filter_field`,
`filter_value`, `filter_operator` (`eq`, `ne`, `lt`, `lte`, `gt`, `gte`,
`contains`), `sort_by`, `sort_direction`, `limit` (at most 100) and
`offset`. `update-user` refuses `id`, `role` and the ban fields: those
have their own endpoints.

The admin dashboard (`Authmk.Dashboard`, licensed separately) does all of
this from its Users page, through these same endpoints and checks. Its
Organizations, Payments and Branding pages need three more statements,
which the default `admin` role has: `organization: create, update,
delete`, `subscription: update` and `branding: update`.

### Banning and impersonating

`POST /auth/admin/ban-user` takes a `user_id`, and optionally a
`ban_reason` and `ban_expires_in` (seconds). It answers with the `user`,
now `banned`. A banned user is signed out everywhere, and no sign-in
method gives them a session until the ban ends: they get the code `banned`
with `banned_user_message`. Without `ban_expires_in` (or the
`default_ban_expires_in` option), a ban lasts until `unban-user`. Admins
can't ban or remove themselves.

`POST /auth/admin/impersonate-user` with a `user_id` signs the admin in as
that user for `impersonation_session_duration` seconds (an hour). The
response has the new `session`, with `impersonated_by_id`, and the `user`.
`POST /auth/admin/stop-impersonating` brings back the admin's own
session. Users with one of `admin_roles` can only be impersonated with
`user: impersonate_admins`.

### Your own roles

Include the admin statements in yours, and pass
`access_control: MyApp.Permissions` to the plugin:

```elixir
defmodule MyApp.Permissions do
  alias Authmk.Plugins.Admin.Permissions, as: Admin
  use Authmk.AccessControl,
    statements: Admin.statements() ++ [project: [:create]],
    roles: [admin: Admin.statements(), support: [user: [:list, :get]], user: [project: [:create]]]
end
```

Keep roles for `default_role` (`user`) and the first of `admin_roles`
(`admin`). This `admin` has every statement, even `impersonate_admins`.

## Organizations

Members with roles, invitations, and optionally teams and custom roles:

```elixir
use Authmk,
  plugins: [{Authmk.Plugins.Organization, send_invitation_email: &MyApp.Mailer.send_invitation/2}],
  ...
```

Whoever creates an organization joins it as `owner` (`creator_role`), and
it becomes their active organization, unless they pass
`keep_current_active_organization: true`:

```http
POST /auth/organization/create
{"name": "Acme", "slug": "acme"}

200 {"id": "...", "name": "Acme", "slug": "acme", "members": [{"role": "owner", ...}]}
```

Endpoints that act on an organization take `organization_id`, or use the
session's active one (`active_organization_id`). Switch with
`POST /auth/organization/set-active` and an `organization_id` or
`organization_slug`. `{"organization_id": null}` leaves none active.

The other endpoints, under `/auth/organization/`: `update`, `delete`,
`list`, `check-slug`, `get-full-organization` (with members, pending
invitations and teams), `list-members`, `remove-member` (by
`member_id_or_email`), `update-member-role`, `get-active-member`,
`get-active-member-role` and `leave`. Limits: `organization_limit` per user
(none by default), `membership_limit` (100) and `invitation_limit` (100
pending). With `allow_user_to_create_organization: false`, only your code
creates organizations.

### Invitations

```http
POST /auth/organization/invite-member
{"email": "grace@example.com", "role": "admin"}

200 {"id": "...", "email": "grace@example.com", "role": "admin", "status": "pending", ...}
```

authmk calls `send_invitation_email` with `%{id:, email:, role:,
organization:, inviter:}` and the context. Link the email to your page
that accepts invitations by id. Only the user with that email may see,
accept or reject it. `POST /auth/organization/accept-invitation` with the
`invitation_id` answers with the `invitation` (now `accepted`) and the new
`member`, and makes the organization active. Invitations expire after
`invitation_expires_in` seconds (two days). Inviting a pending email again
fails with `already_invited`, unless the request has `resend: true` or you
set `cancel_pending_invitations_on_re_invite: true`. With
`require_email_verification_on_invitation: true`, only verified users may
accept or reject. Invitees find theirs with
`GET /auth/organization/list-user-invitations`.

### Organization roles

The default roles, from `Authmk.Plugins.Organization.Permissions`: `owner`
may do everything; `admin` everything but delete the organization
(including its API keys and service accounts); `member` may only read the
organization's roles. Only owners may give, change or take the owner role,
and an organization always keeps one (`cannot_remove_last_owner`).

For your own resources, include the organization statements:

```elixir
defmodule MyApp.OrgPermissions do
  alias Authmk.Plugins.Organization.Permissions
  use Authmk.AccessControl,
    statements: Permissions.statements() ++ [project: [:create, :delete]],
    roles: [
      owner: Permissions.statements() ++ [project: [:create, :delete]],
      developer: [project: [:create]]
    ]
end
```

Pass it as `access_control:`. Only the roles you list exist: here,
inviting someone as `member` fails with `invalid_role`.

With `teams: [enabled: true]`, organizations get teams (`create-team`,
`update-team`, `remove-team`, `list-teams`, `set-active-team`,
`list-user-teams`, `list-team-members`, `add-team-member`,
`remove-team-member`), and invitations take a `team_id`.

With `dynamic_access_control: [enabled: true]`, members with the `ac`
permissions create roles at runtime, like
`{"role": "recruiter", "permission": {"invitation": ["create"]}}` to
`POST /auth/organization/create-role` (and `update-role`, `delete-role`,
`list-roles`, `get-role`). A role grants only what your statements have
and what its creator may do. A role that members still have can't be
deleted (`role_in_use`).

### Hooks and server code

Pass a module as `hooks` to change or stop events, or hear about them. The
events are listed in `Authmk.Plugins.Organization.Hooks`:

```elixir
defmodule MyApp.OrganizationHooks do
  @behaviour Authmk.Plugins.Organization.Hooks

  @impl true
  def before_event(:create_organization, %{"name" => "Forbidden"}, _ctx),
    do: {:error, Authmk.Error.custom(:name_not_allowed, 422, "Pick another name")}
  def before_event(_event, data, _ctx), do: {:ok, data}

  @impl true
  def after_event(event, record, _ctx), do: MyApp.Audit.log(event, record)
end
```

From your own code, such as a back office, `Authmk.Plugins.Organization`
manages organizations without the caller being a member:

```elixir
alias Authmk.Plugins.Organization

{:ok, org} = Organization.create_organization(MyApp.Auth, %{name: "Acme", slug: "acme"}, owner_id)
{:ok, _member} = Organization.add_member(MyApp.Auth, org.id, user_id, "member")
{:ok, _invitation} = Organization.invite_member(MyApp.Auth, org.id, "grace@example.com", "admin", owner_id)
```

The others are `update_organization/3`, `delete_organization/2`,
`set_member_role/4`, `remove_member/3`, `cancel_invitation/2`,
`list_for_user/2`, and with teams `create_team/3`, `update_team/3`,
`remove_team/2`, `add_team_member/3` and `remove_team_member/3`. They make
the endpoints' checks (slugs, roles, limits, the last owner, the last team)
except the caller's own permissions, and run the hooks.
`create_organization/3` skips `allow_user_to_create_organization` and
`organization_limit`, which limit what users do themselves.

## API keys

Users and organizations call your API with keys, shown once and stored hashed:

```elixir
use Authmk,
  plugins: [{Authmk.Plugins.APIKey, configurations: [default: [prefix: "sk_", rate_limit: [max_requests: 1000]]]}],
  ...
```

Each configuration has a rate limit, on by default at **10 requests per
day per key**. Set one that fits your API, or `rate_limit: [enabled: false]`.
Configurations also take `key_length`, `default_expires_in`,
`min_expires_in`, `max_expires_in`, `disable_custom_expires_in`,
`default_permissions`, `require_name` and `enable_metadata`. Clients pick
one with `config_id`.

```http
POST /auth/api-key/create
{"name": "CI", "expires_in": 2592000}

200 {"id": "...", "name": "CI", "start": "sk_AbC", "key": "sk_AbC...", "expires_at": "...", ...}
```

Show `key` now: it can't be read again. `start` tells keys apart. Manage
keys with `GET /auth/api-key/list`, `GET /auth/api-key/get?id=...`,
`POST /auth/api-key/update` (`key_id`, `name`, `enabled`, `metadata`) and
`POST /auth/api-key/delete`. With `organization_id`, a key belongs to an
organization, and managing it takes the `api_key` permission there.

Clients can't set permissions, uses or rate limits. Your server does:

```elixir
{:ok, %{key: key}} =
  Authmk.Plugins.APIKey.create(MyApp.Auth, %{
    user_id: user.id,
    permissions: %{"files" => ["read"]},
    remaining: 1000,
    refill_interval: 86_400,
    refill_amount: 1000
  })

case Authmk.Plugins.APIKey.verify(MyApp.Auth, key, %{"files" => ["read"]}) do
  {:ok, api_key} -> api_key.user_id
  {:error, %Authmk.Error{code: code}} -> code
end
```

`verify/3` checks that the key exists, is enabled, hasn't expired and has
every permission asked for (a key's permissions are its own map, not a
role), then counts one use, atomically. It fails with
`invalid_api_key`, `api_key_disabled`, `api_key_expired`,
`insufficient_api_key_permissions`, `api_key_usage_exceeded` or
`api_key_rate_limited`. `update/3`, `list_for/3`, `delete/2` and
`delete_expired/1` do the rest.

With `enable_sessions: true`, a request with a user's key in `x-api-key`
is signed in as that user, in the auth router and in
`Authmk.Plug.FetchSession`. That session isn't stored and is never fresh.
A bad key gets a 401.

## Service accounts

Service accounts are identities for programs: no email, no password, only
API keys. They belong to a user or an organization. Add
`{Authmk.Plugins.ServiceAccount, access_control: MyApp.Permissions}` next
to `Authmk.Plugins.APIKey`. A user's service accounts take their roles from
that `access_control`, within the user's own `role` (from the Admin plugin).

```http
POST /auth/service-account/create
{"name": "Nightly export", "role": "user", "allowed_ips": ["10.0.0.0/8"]}

200 {"id": "...", "name": "Nightly export", "role": "user", "allowed_ips": ["10.0.0.0/8"], ...}
```

An organization's service accounts (created with `organization_id`) take
its roles. Either way, a service account gets only what its creator may
do. It's refused when disabled, expired (`expires_in`), or called from
outside `allowed_ips`. `POST /auth/service-account/create-key` with its
`id` answers with a new key, shown once. Its keys are API keys, rate limit
included. Rotate them without downtime: create a new key, switch over,
then `POST /auth/service-account/revoke-key` with `id` and `key_id`.

A request with a service account's key is authenticated as the account:
`Authmk.Plug.FetchSession` assigns it as `current_principal`, and
`current_user` stays `nil`. Let it through with
`plug Authmk.Plug.RequireAuthenticated, allow_principals: true`.

## Checking permissions in your code

Guard routes with `Authmk.Plug.RequireRole`, after `Authmk.Plug.FetchSession`:

```elixir
plug Authmk.Plug.RequireRole, roles: ["admin", "support"]
plug Authmk.Plug.RequireRole, auth: MyApp.Auth, permissions: %{project: [:create]}
```

`permissions:` uses the Admin plugin's `access_control` and
`admin_user_ids`. Signed-out requests get 401 and others 403, as JSON, or a
redirect with `redirect_to:`. Service accounts are refused. Elsewhere, ask
your access control module, like
`MyApp.Permissions.has_permission?(user.role, %{project: [:create]})`.

For an organization, read the member's role. With an auth module named
`MyApp.Auth`, members are `MyApp.Auth.Member`:

```elixir
def can?(user, session, permissions) do
  with id when not is_nil(id) <- session.active_organization_id,
       %{role: role} <- MyApp.Repo.get_by(MyApp.Auth.Member, organization_id: id, user_id: user.id) do
    MyApp.OrgPermissions.has_permission?(role, permissions)
  else
    _ -> false
  end
end
```

This knows only the roles in your module, not those organizations
define. Clients ask `POST /auth/organization/has-permission` with
`{"permissions": {"project": ["create"]}}`, which knows both and answers
`{"success": true}` or `{"success": false}` for the signed-in member.

For a service account, ask
`Authmk.Plugins.ServiceAccount.has_permission?(MyApp.Auth, conn.assigns.current_principal, %{project: [:create]})`.
