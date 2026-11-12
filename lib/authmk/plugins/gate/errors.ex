defmodule Authmk.Plugins.Gate.Errors do
  @moduledoc false

  alias Authmk.Error

  @errors %{
    organization_not_found: {404, "Organization not found"},
    team_not_found: {404, "Team not found"},
    member_not_found: {404, "Member not found"},
    role_not_found: {404, "Role not found"},
    invalid_role: {422, "Unknown role"},
    invalid_role_name:
      {422, "Role names are 1 to 64 lowercase letters, digits, underscores or hyphens"},
    invalid_role_level: {422, "Role levels are organization, team and team_member"},
    invalid_permission: {422, "The role grants abilities that don't exist or are app-only"},
    role_limit_reached: {403, "This organization has as many roles as allowed"},
    role_assigned: {409, "Teams or team members still have this role"}
  }

  def error(code) do
    {status, message} = Map.fetch!(@errors, code)
    Error.custom(code, status, message)
  end
end
