defmodule Authmk.Plugins.Organization.Permissions do
  @moduledoc """
  The organization plugin's default access control:

    * `owner` may do everything, including deleting the organization;
    * `admin` may do everything else, including managing the organization's
      API keys;
    * `member` may read the organization's roles.

  To add your own resources and roles, include these statements in yours
  and pass `access_control: MyApp.OrgPermissions` to the plugin:

      use Authmk.AccessControl,
        statements: Authmk.Plugins.Organization.Permissions.statements() ++ [project: [:create]],
        roles: [
          owner: Authmk.Plugins.Organization.Permissions.statements() ++ [project: [:create]],
          member: [project: [:create]]
        ]
  """

  @statements [
    organization: [:update, :delete],
    member: [:create, :update, :delete],
    invitation: [:create, :cancel],
    team: [:create, :update, :delete],
    ac: [:create, :read, :update, :delete],
    # Keys owned by the organization (Authmk.Plugins.APIKey).
    api_key: [:create, :read, :update, :delete],
    # The organization's service accounts (Authmk.Plugins.ServiceAccount).
    service_account: [:create, :read, :update, :delete]
  ]

  @doc "The organization actions, as access control statements."
  @spec statements() :: keyword()
  def statements, do: @statements

  use Authmk.AccessControl,
    statements: @statements,
    roles: [
      owner: @statements,
      admin: Keyword.put(@statements, :organization, [:update]),
      member: [ac: [:read]]
    ]
end
