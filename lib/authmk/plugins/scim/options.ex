defmodule Authmk.Plugins.SCIM.Options do
  @moduledoc false

  def schema do
    NimbleOptions.new!(
      can_manage: [
        type: {:fun, 3},
        doc:
          "`fn action, organization_id, ctx -> boolean end` for `:create`, `:read`, `:rotate` and `:decommission` on an organization's connections. Without it, no one manages them through the endpoints; use `create_connection/3`."
      ],
      on_delete: [
        type: {:in, [:deactivate, :delete]},
        default: :deactivate,
        doc:
          "What `DELETE /Users/:id` does: deactivate the user (kept, can't sign in), or delete them."
      ],
      link_existing_users: [
        type: :boolean,
        default: false,
        doc:
          "Link a provisioned user to an existing user with the same email. Off by default: provisioning then fails with `uniqueness`, so no connection takes over accounts it doesn't own."
      ],
      resolve_user: [
        type: {:fun, 3},
        doc:
          "`fn scim_user, connection, ctx -> {:ok, user} | :create | {:error, reason} end`: pick the user a provisioned identity is, before the default rules."
      ],
      group_roles: [
        type: {:fun, 1},
        doc:
          "`fn group_display_name -> role | nil end`: organization roles for members of groups (with `Authmk.Plugins.Organization`). A user's role is the first of their groups' roles, in `role_priority` order."
      ],
      role_priority: [
        type: {:list, :string},
        default: ["owner", "admin", "member"],
        doc: "Roles from most to least privileged, to pick one when groups give several."
      ],
      default_role: [
        type: :string,
        default: "member",
        doc: "Role of provisioned users without a group role."
      ],
      max_results: [
        type: :pos_integer,
        default: 100,
        doc: "Most resources one list answer holds."
      ]
    )
  end
end
