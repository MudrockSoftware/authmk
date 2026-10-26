defmodule Authmk.Plugins.Organization.Errors do
  @moduledoc false

  alias Authmk.Error

  @errors %{
    organization_not_found: {404, "Organization not found"},
    not_a_member: {403, "You aren't a member of this organization"},
    no_active_organization: {400, "No organization is active; pass organization_id"},
    slug_taken: {422, "This slug is taken"},
    organization_creation_disabled: {403, "You can't create organizations"},
    organization_limit_reached: {403, "You belong to as many organizations as allowed"},
    membership_limit_reached: {403, "This organization has as many members as allowed"},
    invitation_limit_reached:
      {403, "This organization has as many pending invitations as allowed"},
    invitation_not_found: {404, "Invitation not found"},
    invitation_expired: {400, "This invitation has expired"},
    already_member: {409, "This user is already a member"},
    already_invited: {409, "This user is already invited"},
    member_not_found: {404, "Member not found"},
    cannot_remove_last_owner: {400, "An organization needs an owner"},
    owner_required: {403, "Only owners can do this"},
    invalid_role: {422, "Unknown role"},
    email_not_verified: {403, "Verify your email first"},
    team_not_found: {404, "Team not found"},
    team_limit_reached: {403, "This organization has as many teams as allowed"},
    team_member_limit_reached: {403, "This team has as many members as allowed"},
    cannot_remove_last_team: {400, "An organization needs a team"},
    role_not_found: {404, "Role not found"},
    role_exists: {409, "This role exists already"},
    role_limit_reached: {403, "This organization has as many roles as allowed"},
    role_in_use: {409, "Members still have this role"}
  }

  def error(code) do
    {status, message} = Map.fetch!(@errors, code)
    Error.custom(code, status, message)
  end
end
