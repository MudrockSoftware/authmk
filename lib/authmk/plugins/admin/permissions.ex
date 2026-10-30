defmodule Authmk.Plugins.Admin.Permissions do
  @moduledoc """
  The admin plugin's default access control: an `admin` role that may do
  every admin action (users, sessions, service accounts, and in the
  dashboard organizations, subscriptions and branding) except
  impersonating other admins, and a `user` role that may do none.

  To add your own resources and roles, include these statements in yours:

      defmodule MyApp.Permissions do
        use Authmk.AccessControl,
          statements: Authmk.Plugins.Admin.Permissions.statements() ++ [project: [:create]],
          roles: [
            admin: Authmk.Plugins.Admin.Permissions.statements(),
            support: [user: [:list, :get], session: [:list, :revoke]],
            user: [project: [:create]]
          ]
      end

  and pass `access_control: MyApp.Permissions` to the plugin.
  """

  @statements [
    user: [
      :create,
      :list,
      :get,
      :update,
      :set_role,
      :set_password,
      :ban,
      :impersonate,
      :impersonate_admins,
      :delete
    ],
    session: [:list, :revoke],
    service_account: [:list, :update, :delete],
    # Authmk.Dashboard's: any organization, any subscription, the branding.
    organization: [:create, :update, :delete],
    subscription: [:update],
    branding: [:update]
  ]

  @doc "The admin actions, as access control statements."
  @spec statements() :: keyword()
  def statements, do: @statements

  use Authmk.AccessControl,
    statements: @statements,
    roles: [
      admin: [
        user: @statements[:user] -- [:impersonate_admins],
        session: @statements[:session],
        service_account: @statements[:service_account],
        organization: @statements[:organization],
        subscription: @statements[:subscription],
        branding: @statements[:branding]
      ],
      user: []
    ]
end
