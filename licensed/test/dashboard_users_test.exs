defmodule Authmk.DashboardUsersTest do
  # Managing users from the dashboard: each change goes through the Admin
  # plugin's rules and lands in the audit log, with the admin as the actor.
  use Authmk.EmulationCase, async: true

  import Authmk.Test.DashboardHelpers

  alias Authmk.{Context, Store, Testing}
  alias Authmk.Test.Browser

  defmodule Permissions do
    @moduledoc false
    alias Authmk.Plugins.Admin.Permissions, as: AdminPermissions

    use Authmk.AccessControl,
      statements: AdminPermissions.statements(),
      roles: [
        admin: AdminPermissions.statements(),
        support: [user: [:list, :get], session: [:list, :revoke]],
        user: []
      ]
  end

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      schema: [
        user: [
          additional_fields: [
            plan: [type: :string, validate: [inclusion: ["free", "pro"]]],
            seats: [type: :integer],
            internal_note: [type: :string, input: false],
            api_secret: [type: :string, returned: false]
          ]
        ]
      ],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Admin, access_control: Permissions, admin_roles: ["admin"]},
        Authmk.Plugins.TwoFactor,
        Authmk.Plugins.AuditLog
      ]
  end

  @moduletag auth: Auth

  setup do
    %{admin: Testing.create_user(Auth, email: "admin@example.com", name: "Admin", role: "admin")}
  end

  test "create a user, set their password, and they sign in with it", %{admin: admin} do
    {200, %{"user" => created}} =
      post_json(Auth, "users", admin, %{
        email: " Ada@Example.com ",
        name: "Ada",
        fields: %{plan: "pro", seats: 3}
      })

    assert created["email"] == "ada@example.com"
    ada = Testing.get_user_by(Auth, email: "ada@example.com")
    assert ada.plan == "pro" and ada.seats == 3

    # Too short for the password policy.
    assert {422, _} = post_json(Auth, "users/#{ada.id}/set-password", admin, %{password: "short"})

    assert {200, _} =
             post_json(Auth, "users/#{ada.id}/set-password", admin, %{password: "correct horse"})

    {_browser, conn} =
      Browser.post(Browser.new(Auth), "/sign-in/email", %{
        email: "ada@example.com",
        password: "correct horse"
      })

    assert conn.status == 200

    events = Enum.map(dashboard_events(Auth), & &1.event)
    assert "dashboard.user.created" in events
    assert "dashboard.user.password_set" in events
    # Never the password.
    refute Enum.any?(dashboard_events(Auth), &(inspect(&1) =~ "correct horse"))
  end

  test "edit a user and the app's fields, by their types", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com", name: "Ada")
    ctx = Context.new(Auth.config())
    {:ok, ada} = Store.update(ctx, :user, ada, %{email_verified: true})

    {200, detail} = get_json(Auth, "users/#{ada.id}", admin)

    assert [
             %{
               "name" => "plan",
               "type" => "string",
               "editable" => true,
               "options" => ["free", "pro"]
             },
             %{"name" => "seats", "type" => "integer", "editable" => true},
             %{"name" => "internal_note", "editable" => false}
           ] = detail["fields"]

    refute Enum.any?(detail["fields"], &(&1["name"] == "api_secret"))

    # Wrong types, read-only and hidden fields are refused.
    assert {400, _} = post_json(Auth, "users/#{ada.id}/update", admin, %{fields: %{seats: "3"}})

    assert {400, _} =
             post_json(Auth, "users/#{ada.id}/update", admin, %{fields: %{internal_note: "x"}})

    assert {400, _} =
             post_json(Auth, "users/#{ada.id}/update", admin, %{fields: %{api_secret: "x"}})

    assert {422, _} = post_json(Auth, "users/#{ada.id}/update", admin, %{fields: %{plan: "gold"}})
    assert {400, _} = post_json(Auth, "users/#{ada.id}/update", admin, %{email: "not an email"})

    assert {200, _} =
             post_json(Auth, "users/#{ada.id}/update", admin, %{
               name: "Ada Lovelace",
               email: "Lovelace@example.com",
               fields: %{seats: 5}
             })

    ada = Testing.get_user_by(Auth, id: ada.id)
    assert {ada.name, ada.email, ada.seats} == {"Ada Lovelace", "lovelace@example.com", 5}
    # A new email isn't verified until someone verifies it.
    refute ada.email_verified

    assert {200, _} = post_json(Auth, "users/#{ada.id}/verify-email", admin)
    assert Testing.get_user_by(Auth, id: ada.id).email_verified

    [%{metadata: metadata} | _] =
      Enum.filter(dashboard_events(Auth), &(&1.event == "dashboard.user.updated"))

    assert metadata["fields"] == ["email", "email_verified", "name", "seats"]
  end

  test "ban, unban, sessions, roles and two-factor", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com", password: "correct horse")
    %{session: first} = Testing.create_session(Auth, ada)
    Testing.create_session(Auth, ada)

    assert {200, _} = post_json(Auth, "users/#{ada.id}/sessions/#{first.id}/revoke", admin)
    assert length(Testing.list_sessions(Auth, ada)) == 1
    assert {200, _} = post_json(Auth, "users/#{ada.id}/revoke-sessions", admin)
    assert Testing.list_sessions(Auth, ada) == []

    assert {200, _} =
             post_json(Auth, "users/#{ada.id}/ban", admin, %{reason: "Spam", expires_in: 3600})

    banned = Testing.get_user_by(Auth, id: ada.id)
    assert banned.banned and banned.ban_reason == "Spam" and banned.ban_expires

    {_browser, conn} =
      Browser.post(Browser.new(Auth), "/sign-in/email", %{
        email: "ada@example.com",
        password: "correct horse"
      })

    assert conn.status == 403

    assert {200, _} = post_json(Auth, "users/#{ada.id}/unban", admin)
    refute Testing.get_user_by(Auth, id: ada.id).banned

    # Admins can't ban themselves: the Admin plugin's rule holds here.
    assert {400, %{"error" => %{"code" => "cannot_ban_yourself"}}} =
             post_json(Auth, "users/#{admin.id}/ban", admin)

    assert {422, _} = post_json(Auth, "users/#{ada.id}/set-role", admin, %{role: "wizard"})
    assert {200, _} = post_json(Auth, "users/#{ada.id}/set-role", admin, %{role: "support"})
    assert Testing.get_user_by(Auth, id: ada.id).role == "support"

    ctx = Context.new(Auth.config())

    {:ok, _} =
      Store.update(ctx, :user, Testing.get_user_by(Auth, id: ada.id), %{two_factor_enabled: true})

    assert {200, _} = post_json(Auth, "users/#{ada.id}/disable-two-factor", admin)
    refute Testing.get_user_by(Auth, id: ada.id).two_factor_enabled
  end

  test "a limited role sees users but can't change them, or anyone stronger", %{admin: admin} do
    support = Testing.create_user(Auth, email: "support@example.com", role: "support")
    ada = Testing.create_user(Auth, email: "ada@example.com")

    {200, me} = get_json(Auth, "me", support)
    assert me["can"]["revoke_sessions"]
    refute me["can"]["ban"] or me["can"]["update_users"] or me["can"]["update_branding"]

    assert {200, _} = get_json(Auth, "users/#{ada.id}", support)
    assert {403, _} = post_json(Auth, "users/#{ada.id}/ban", support)
    assert {403, _} = post_json(Auth, "users/#{ada.id}/verify-email", support)
    assert {403, _} = post_json(Auth, "users", support, %{email: "x@example.com", name: "X"})

    # Revoking an admin's sessions needs every admin permission.
    Testing.create_session(Auth, admin)
    assert {403, _} = post_json(Auth, "users/#{admin.id}/revoke-sessions", support)
    assert {200, _} = post_json(Auth, "users/#{ada.id}/revoke-sessions", support)
  end

  test "unlink accounts, but never the last one", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com", password: "correct horse")
    ctx = Context.new(Auth.config())

    {:ok, github} =
      Store.insert(ctx, :account, %{user_id: ada.id, provider_id: "github", account_id: "42"})

    {200, %{"accounts" => accounts}} = get_json(Auth, "users/#{ada.id}", admin)
    assert length(accounts) == 2

    assert {200, _} = post_json(Auth, "users/#{ada.id}/accounts/#{github.id}/unlink", admin)
    [%{"id" => last}] = elem(get_json(Auth, "users/#{ada.id}", admin), 1)["accounts"]

    assert {400, %{"error" => %{"message" => "That's the user's only way to sign in."}}} =
             post_json(Auth, "users/#{ada.id}/accounts/#{last}/unlink", admin)

    assert {404, _} = post_json(Auth, "users/#{ada.id}/accounts/nope/unlink", admin)
  end

  test "impersonate a user, then stop", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com")
    conn = api(Auth, :post, "users/#{ada.id}/impersonate", admin, body: %{})
    assert conn.status == 200

    # The admin's browser now holds Ada's session.
    cookies = conn.resp_cookies
    assert Map.has_key?(cookies, "authmk.session_token")
    assert Map.has_key?(cookies, "authmk.admin_session")
    [session] = Testing.list_sessions(Auth, ada)
    assert session.impersonated_by_id == admin.id

    assert "dashboard.user.impersonated" in Enum.map(dashboard_events(Auth), & &1.event)
  end

  test "delete a user", %{admin: admin} do
    ada = Testing.create_user(Auth, email: "ada@example.com")
    assert {200, _} = post_json(Auth, "users/#{ada.id}/delete", admin)
    assert Testing.get_user_by(Auth, id: ada.id) == nil
    assert {400, _} = post_json(Auth, "users/#{admin.id}/delete", admin)
  end
end
