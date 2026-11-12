defmodule Authmk.Plugins.Gate.Options do
  @moduledoc false

  @grants {:or,
           [:keyword_list, {:map, {:or, [:atom, :string]}, {:list, {:or, [:atom, :string]}}}]}
  @roles {:or, [:keyword_list, {:map, {:or, [:atom, :string]}, @grants}]}

  @schema NimbleOptions.new!(
            abilities: [
              type: :keyword_list,
              required: true,
              doc:
                "The resources and their actions, like `[invoice: [:view, :update], report: [:view]]`."
            ],
            app_roles: [
              type: @roles,
              default: [],
              doc:
                "What app roles (the user's `role`) may do, everywhere: `[support: [invoice: [:view]]]`. App admins may do everything."
            ],
            organization_roles: [
              type: @roles,
              default: [],
              doc:
                "What organization member roles may do in their organization, like `[member: [report: [:view]]]`. Organization admins may do everything there. Needs `Authmk.Plugins.Organization`."
            ],
            team_roles: [
              type: @roles,
              default: [],
              doc:
                "What a team with this role may do in its organization; its members inherit it. Needs teams."
            ],
            team_member_roles: [
              type: @roles,
              default: [],
              doc:
                "What a team member with this role may do of what their team may do. Members without a role get all of it. Needs teams."
            ],
            app_only: [
              type: :keyword_list,
              default: [],
              doc:
                "Abilities only app roles may grant, like `[billing: [:refund]]`. No organization role, team role or organization admin gets them."
            ],
            organization_admin_roles: [
              type: {:list, :string},
              default: ["owner", "admin"],
              doc: "Organization member roles that may do everything in their organization."
            ],
            default_team_member_role: [
              type: :string,
              doc:
                "The role new team members get, so nobody joins a team with all of its access by accident."
            ],
            maximum_roles_per_organization: [
              type: :pos_integer,
              default: 100,
              doc: "Roles an organization may define or override, over every level."
            ]
          )

  def schema, do: @schema
end
