defmodule Authmk.Plugins.Organization.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            access_control: [
              type: :atom,
              default: Authmk.Plugins.Organization.Permissions,
              doc:
                "A module that uses `Authmk.AccessControl`, with the organization statements (see `Authmk.Plugins.Organization.Permissions`)."
            ],
            creator_role: [
              type: :string,
              default: "owner",
              doc: "The role of whoever creates an organization."
            ],
            allow_user_to_create_organization: [type: :boolean, default: true],
            organization_limit: [
              type: :pos_integer,
              doc: "Organizations a user may belong to. Unlimited without it."
            ],
            membership_limit: [type: :pos_integer, default: 100, doc: "Members per organization."],
            invitation_limit: [
              type: :pos_integer,
              default: 100,
              doc: "Pending invitations per organization."
            ],
            invitation_expires_in: [type: :pos_integer, default: 172_800, doc: "Seconds."],
            cancel_pending_invitations_on_re_invite: [
              type: :boolean,
              default: false,
              doc: "Inviting someone again replaces their pending invitation instead of failing."
            ],
            require_email_verification_on_invitation: [
              type: :boolean,
              default: false,
              doc: "Only users with a verified email may accept or reject invitations."
            ],
            send_invitation_email: [
              type: {:fun, 2},
              doc:
                "Sends an invitation: called with `%{id: id, email: email, role: role, organization: org, inviter: user}` and the context. Link it to your page that accepts invitations by id."
            ],
            hooks: [
              type: :atom,
              doc: "A module implementing `Authmk.Plugins.Organization.Hooks`."
            ],
            teams: [
              type: :keyword_list,
              default: [],
              keys: [
                enabled: [type: :boolean, default: false],
                maximum_teams: [type: :pos_integer, doc: "Teams per organization."],
                maximum_members_per_team: [type: :pos_integer],
                allow_removing_all_teams: [type: :boolean, default: true]
              ]
            ],
            dynamic_access_control: [
              type: :keyword_list,
              default: [],
              keys: [
                enabled: [
                  type: :boolean,
                  default: false,
                  doc: "Organizations create their own roles at runtime."
                ],
                maximum_roles_per_organization: [type: :pos_integer]
              ]
            ]
          )

  def schema, do: @schema
end
