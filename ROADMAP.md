# Roadmap

This is the feature plan for the releases after authmk 1.1. Items are grouped
into milestones; each milestone builds on the previous ones. Everything ships
as core functionality or as a plugin built on the public plugin API. What
earlier releases shipped is in [CHANGELOG.md](CHANGELOG.md).

Legend: `[ ]` planned, `[x]` done

---

## 1.2 Authorization

An authorization plugin in the spirit of Laravel's Gate (working name
`Authmk.Plugins.Gate`): apps ask "may this user do this action on this
resource?" and get a clear yes or no. Access can come from the user's app
role, their role in an organization, their teams' roles and their role
inside each team. Apps declare abilities and default access in code. Each
organization can adjust its teams' access within what the code allows.

Every app is different, so the plugin works with only the Admin plugin and
uses organizations and teams when the app has them.

### Model

**Where roles come from**

| Level | Stored on | Values | Needs |
|---|---|---|---|
| App | `user.role` | `admin` and roles declared in code | Admin plugin (required) |
| Organization | the org member's role | `owner`, `admin`, `member` | Organization plugin |
| Team | `team.role` (new, nullable) | declared in code or created by the org | Organization plugin with teams |
| Team member | `team_member.role` (new, nullable) | declared in code or created by the org, e.g. `employee`, `manager`, `editor` | Organization plugin with teams |

authmk ships no preset team or team member roles. A user can belong to many
organizations with a different role in each (as in Microsoft Entra), for
example admin in one and member in another.

**How a check is decided**

For `allows?(user, {:reports, :view}, report)`:

1. An app admin may do everything, everywhere.
2. The user's other app roles grant what the code gives them, across every
   organization. They are meant for the app's own staff.
3. If the resource belongs to an organization:
   - An owner or admin of **that** organization may do everything inside it,
     and nothing in organizations where they are only a member.
   - Otherwise, each of the user's teams in that organization gets what its
     team role is allowed **in that organization**: the organization's own
     setting if it has one, else the default from code. Team members inherit
     their team's access.
   - A team member role can only narrow the team's access, never widen it.
     For example, `employee` may only view while `manager` or `editor` may
     also update. A member with no role gets all of the team's access.
   - A user in several teams gets the access of all of them combined.
4. Everything else is denied.

The organization always comes from the resource being checked, never from
the session's active organization, so an admin of one organization can't act
on another's data. Checks fail closed: an unknown ability, a resource
without an organization where one is needed, or a failed database read all
mean "no". Access is read from the database for each request, not cached,
so a change takes effect on the next request.

**Defaults and overrides**

- Code declares the abilities (resources and their actions, as in
  `Authmk.AccessControl`), the app roles, and default access for team roles
  and team member roles. Those defaults apply in every organization.
- Each organization can override the access of team roles and team member
  roles, and create its own roles, usable by any team in that organization.
- Overrides can only use abilities declared in code. Abilities can be
  marked app-only, so no organization can ever grant them.
- Roles declared in code are read-only in the dashboard. Code always wins.
- App admins edit overrides in the dashboard. Organization admins edit them
  through the public API and endpoints, so apps can build their own
  administration menus for organization admins.
- Only app admins can open the admin dashboard, unless the code lists more
  app roles.

**Defaults to confirm while building**

- An organization `owner` is treated exactly like `admin`.
- An organization `member` who is in no team gets nothing, unless the code
  sets a default for members.
- An optional `default_member_role:` gives new team members a role, so
  nobody added without a role gets the team's full access by accident.

**Where the code lives**

The checks, the roles and the overrides table are MIT, in `lib/`, so an app's
authorization keeps working if a licence key lapses. Only the dashboard's
editor for roles and overrides is licensed, in `licensed/`.

### Core (Admin plugin only)

- [ ] Plugin config validated with NimbleOptions: abilities, app roles, default access, dashboard roles; compile-time errors for unknown abilities, and for team rules when teams are off
- [ ] `allows?/3` and `authorize/3` (`:ok` or `%Authmk.Error{code: "forbidden"}`) on the auth module, with and without a resource
- [ ] App admin may do everything; other app roles grant what the code declares
- [ ] A Plug and a LiveView `on_mount` hook that require an ability
- [ ] Telemetry for denied checks, without leaking resource data

### Organizations and teams

- [ ] Nullable `role` on `team` and `team_member`, with migrations from `mix authmk.gen.migration`
- [ ] Organization owner and admin may do everything inside their own organization only
- [ ] Team access from the team role, inherited by its members
- [ ] Team member roles narrow the team's access
- [ ] Access combined across several teams, per organization
- [ ] Organization taken from the resource; rejected when a resource doesn't say which organization it belongs to
- [ ] Optional `default_member_role:` and default access for plain organization members

### Per-organization overrides and roles

- [ ] Table for per-organization overrides of team role and team member role access
- [ ] Organizations create their own team and team member roles
- [ ] App-only abilities that overrides can never grant
- [ ] Public functions and endpoints for organization admins to read and change their organization's access
- [ ] Audit events for every change

### Dashboard (licensed)

- [ ] Roles and default access per level, with code-declared roles read-only
- [ ] Per-organization overrides and organization roles
- [ ] App roles allowed into the dashboard, when the code lists them
- [ ] The user permissions view shows access from team roles, member roles and overrides

### Example apps, docs and tests

- [ ] Emulation tests for full flows: app roles only, organizations, teams, overrides, cross-organization attempts
- [ ] Fuzz tests for override and ability input from requests
- [ ] Both example apps: pages guarded by abilities, team roles, an organization admin screen for overrides
- [ ] README, module docs and a guide
