defmodule Authmk.Plugins.Admin.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            access_control: [
              type: :atom,
              default: Authmk.Plugins.Admin.Permissions,
              doc:
                "A module that uses `Authmk.AccessControl`, with the admin statements (see `Authmk.Plugins.Admin.Permissions`)."
            ],
            default_role: [type: :string, default: "user", doc: "The role of new users."],
            admin_roles: [
              type: {:list, :string},
              default: ["admin"],
              doc:
                "Roles whose users count as admins: only `impersonate_admins` may impersonate them."
            ],
            admin_user_ids: [
              type: {:list, :string},
              default: [],
              doc: "Users who may do every admin action, whatever their role."
            ],
            impersonation_session_duration: [
              type: :pos_integer,
              default: 3600,
              doc: "Seconds an impersonation lasts."
            ],
            default_ban_reason: [type: :string, default: "No reason given"],
            default_ban_expires_in: [
              type: :pos_integer,
              doc:
                "Seconds a ban lasts when the request doesn't say. Without it, bans don't expire."
            ],
            banned_user_message: [
              type: :string,
              default: "You have been banned from this application",
              doc: "What banned users see when they try to sign in."
            ]
          )

  def schema, do: @schema
end
