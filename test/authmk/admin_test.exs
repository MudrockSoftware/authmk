defmodule Authmk.AdminTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.TwoFactor, skip_verification_on_enable: true},
        {Authmk.Plugins.Admin, impersonation_session_duration: 600}
      ]
  end

  @moduletag auth: Auth

  @password "correct horse"

  # Signs up and makes the user an admin, the way an app would seed its first one.
  defp sign_up_admin(browser, email \\ "admin@example.com") do
    {browser, user} = sign_up(browser, %{email: email, name: "Root"})
    set_role(user["id"], "admin")
    {browser, user}
  end

  defp set_role(user_id, role) do
    module = Authmk.Store.module(Authmk.Context.new(Auth.config()), :user)
    Repo.update_all(where(module, id: ^user_id), set: [role: role])
  end

  defp new_user(email, name \\ "User") do
    {browser, user} = sign_up(Browser.new(Auth), %{email: email, name: name})
    {browser, user}
  end

  defp signed_in_user(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]
  end

  test "new users get the default role", %{browser: browser} do
    {_browser, user} = sign_up(browser)
    assert user["role"] == "user"
    assert user["banned"] == false
  end

  test "plain users can't do admin actions", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_victim, victim} = new_user("grace@example.com")

    for {method, path, params} <- [
          {:get, "/admin/list-users", %{}},
          {:post, "/admin/set-role", %{user_id: victim["id"], role: "admin"}},
          {:post, "/admin/ban-user", %{user_id: victim["id"]}},
          {:post, "/admin/impersonate-user", %{user_id: victim["id"]}},
          {:post, "/admin/remove-user", %{user_id: victim["id"]}}
        ] do
      {_browser, conn} = request(browser, method, path, params)
      assert conn.status == 403, path
    end

    assert Repo.aggregate("users", :count) == 2
  end

  describe "managing users" do
    test "create, get, update, set role and password, remove", %{browser: browser} do
      {browser, _admin} = sign_up_admin(browser)

      {browser, conn} =
        post(browser, "/admin/create-user", %{
          email: "Grace@Example.com",
          name: "Grace",
          password: "a strong password",
          role: "admin",
          data: %{"email_verified" => true}
        })

      grace = json(conn)["user"]
      assert grace["email"] == "grace@example.com"
      assert grace["role"] == "admin"
      assert grace["email_verified"] == true

      {browser, conn} = get(browser, "/admin/get-user", %{id: grace["id"]})
      assert json(conn)["user"]["name"] == "Grace"

      {browser, conn} =
        post(browser, "/admin/update-user", %{
          user_id: grace["id"],
          data: %{name: "Grace H.", role: "admin,user"}
        })

      # Roles change only through set-role.
      assert json(conn)["user"]["name"] == "Grace H."
      assert json(conn)["user"]["role"] == "admin"

      {browser, conn} =
        post(browser, "/admin/set-role", %{user_id: grace["id"], role: "superuser"})

      assert json(conn)["error"]["code"] == "invalid_role"
      {browser, conn} = post(browser, "/admin/set-role", %{user_id: grace["id"], role: "user"})
      assert json(conn)["user"]["role"] == "user"

      {browser, _conn} =
        post(browser, "/admin/set-user-password", %{
          user_id: grace["id"],
          new_password: "another password"
        })

      {_grace, conn} =
        post(Browser.new(Auth), "/sign-in/email", %{
          email: "grace@example.com",
          password: "another password"
        })

      assert json(conn)["user"]["email"] == "grace@example.com"

      {browser, conn} = post(browser, "/admin/remove-user", %{user_id: grace["id"]})
      assert json(conn) == %{"status" => true}
      {_browser, conn} = get(browser, "/admin/get-user", %{id: grace["id"]})
      assert json(conn)["error"]["code"] == "user_not_found"
    end

    test "admins can't remove or ban themselves", %{browser: browser} do
      {browser, admin} = sign_up_admin(browser)
      {browser, conn} = post(browser, "/admin/remove-user", %{user_id: admin["id"]})
      assert json(conn)["error"]["code"] == "cannot_remove_yourself"
      {_browser, conn} = post(browser, "/admin/ban-user", %{user_id: admin["id"]})
      assert json(conn)["error"]["code"] == "cannot_ban_yourself"
    end

    test "list with search, filter, sort and pages", %{browser: browser} do
      {browser, _admin} = sign_up_admin(browser)

      for {email, name} <- [
            {"ada@lovelace.example", "Ada"},
            {"alan@turing.example", "Alan"},
            {"grace@hopper.example", "Grace"}
          ] do
        new_user(email, name)
      end

      {browser, conn} =
        get(browser, "/admin/list-users", %{
          search_value: "A",
          search_field: "name",
          search_operator: "starts_with",
          sort_by: "name"
        })

      assert Enum.map(json(conn)["users"], & &1["name"]) == ["Ada", "Alan"]
      assert json(conn)["total"] == 2

      {browser, conn} = get(browser, "/admin/list-users", %{search_value: "example"})
      assert json(conn)["total"] == 4

      # Wildcards are literal.
      {browser, conn} = get(browser, "/admin/list-users", %{search_value: "%"})
      assert json(conn)["total"] == 0

      {browser, conn} =
        get(browser, "/admin/list-users", %{filter_field: "role", filter_value: "admin"})

      assert Enum.map(json(conn)["users"], & &1["email"]) == ["admin@example.com"]

      {browser, conn} =
        get(browser, "/admin/list-users", %{
          filter_field: "role",
          filter_value: "admin",
          filter_operator: "ne"
        })

      assert json(conn)["total"] == 3

      {browser, conn} =
        get(browser, "/admin/list-users", %{
          sort_by: "email",
          sort_direction: "desc",
          limit: 2,
          offset: 1
        })

      body = json(conn)

      # grace, alan, admin, ada: the second and third.
      assert Enum.map(body["users"], & &1["email"]) == [
               "alan@turing.example",
               "admin@example.com"
             ]

      assert body["total"] == 4
      assert body["limit"] == 2
      assert body["offset"] == 1

      {_browser, conn} = get(browser, "/admin/list-users", %{sort_by: "password"})
      assert json(conn)["error"]["code"] == "bad_request"
    end
  end

  test "every filter and search operator", %{browser: browser} do
    {browser, _admin} = sign_up_admin(browser)
    {_ada, _user} = new_user("ada@lovelace.example", "Ada")
    {_alan, _user} = new_user("alan@turing.example", "Alan")

    count = fn params ->
      {_browser, conn} = get(browser, "/admin/list-users", params)
      json(conn)["total"]
    end

    now = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))

    assert count.(%{search_value: ".example", search_operator: "ends_with"}) == 2
    assert count.(%{filter_field: "name", filter_value: "la", filter_operator: "contains"}) == 1
    assert count.(%{filter_field: "email_verified", filter_value: "false"}) == 3
    assert count.(%{filter_field: "inserted_at", filter_value: now, filter_operator: "lt"}) == 3
    assert count.(%{filter_field: "inserted_at", filter_value: now, filter_operator: "lte"}) == 3
    assert count.(%{filter_field: "inserted_at", filter_value: now, filter_operator: "gt"}) == 0
    assert count.(%{filter_field: "inserted_at", filter_value: now, filter_operator: "gte"}) == 0
    assert count.(%{filter_field: "ban_reason", filter_operator: "eq"}) == 3
    assert count.(%{filter_field: "ban_reason", filter_operator: "ne"}) == 0

    for bad <- [
          %{filter_field: "password"},
          %{search_value: "x", search_field: "email_verified"},
          %{filter_field: "inserted_at", filter_value: "yesterday"}
        ] do
      {_browser, conn} = get(browser, "/admin/list-users", bad)
      assert json(conn)["error"]["code"] == "bad_request", inspect(bad)
    end
  end

  describe "bans" do
    test "a banned user is signed out and can't sign in, by any method", %{browser: browser} do
      {browser, _admin} = sign_up_admin(browser)
      {victim, victim_user} = new_user("grace@example.com")

      {browser, conn} =
        post(browser, "/admin/ban-user", %{user_id: victim_user["id"], ban_reason: "Spam"})

      assert json(conn)["user"]["banned"] == true
      assert json(conn)["user"]["ban_reason"] == "Spam"

      assert signed_in_user(victim) == nil

      {_victim, conn} =
        post(Browser.new(Auth), "/sign-in/email", %{
          email: "grace@example.com",
          password: @password
        })

      assert conn.status == 403

      assert json(conn)["error"] == %{
               "code" => "banned",
               "message" => "You have been banned from this application",
               "details" => %{}
             }

      {_browser, conn} = post(browser, "/admin/unban-user", %{user_id: victim_user["id"]})
      assert json(conn)["user"]["banned"] == false

      {_victim, conn} =
        post(Browser.new(Auth), "/sign-in/email", %{
          email: "grace@example.com",
          password: @password
        })

      assert json(conn)["user"]["email"] == "grace@example.com"
    end

    test "a ban holds after a second factor too", %{browser: browser} do
      {browser, _admin} = sign_up_admin(browser)
      {victim, victim_user} = new_user("grace@example.com")
      {victim, conn} = post(victim, "/two-factor/enable", %{password: @password})

      secret =
        json(conn)["totp_uri"]
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("secret")
        |> Base.decode32!(padding: false)

      {_victim, _conn} = post(victim, "/sign-out")

      {_browser, _conn} = post(browser, "/admin/ban-user", %{user_id: victim_user["id"]})

      {victim, conn} =
        post(Browser.new(Auth), "/sign-in/email", %{
          email: "grace@example.com",
          password: @password
        })

      assert json(conn)["two_factor_redirect"] == true

      {victim, conn} =
        post(victim, "/two-factor/verify-totp", %{code: NimbleTOTP.verification_code(secret)})

      assert json(conn)["error"]["code"] == "banned"
      assert signed_in_user(victim) == nil
    end

    test "bans end when they expire", %{browser: browser} do
      {browser, _admin} = sign_up_admin(browser)
      {_victim, victim_user} = new_user("grace@example.com")

      {_browser, _conn} =
        post(browser, "/admin/ban-user", %{user_id: victim_user["id"], ban_expires_in: 60})

      module = Authmk.Store.module(Authmk.Context.new(Auth.config()), :user)
      past = DateTime.add(DateTime.utc_now(), -1)
      Repo.update_all(where(module, id: ^victim_user["id"]), set: [ban_expires: past])

      {victim, conn} =
        post(Browser.new(Auth), "/sign-in/email", %{
          email: "grace@example.com",
          password: @password
        })

      assert json(conn)["user"]["email"] == "grace@example.com"
      assert signed_in_user(victim)["banned"] == false
    end
  end

  describe "sessions" do
    test "list and revoke a user's sessions", %{browser: browser} do
      {browser, _admin} = sign_up_admin(browser)
      {victim, victim_user} = new_user("grace@example.com")

      {other_device, _conn} =
        post(Browser.new(Auth), "/sign-in/email", %{
          email: "grace@example.com",
          password: @password
        })

      {browser, conn} = post(browser, "/admin/list-user-sessions", %{user_id: victim_user["id"]})
      [first | _] = sessions = json(conn)["sessions"]
      assert length(sessions) == 2

      {browser, _conn} =
        post(browser, "/admin/revoke-user-session", %{
          user_id: victim_user["id"],
          session_id: first["id"]
        })

      {browser, conn} = post(browser, "/admin/list-user-sessions", %{user_id: victim_user["id"]})
      assert length(json(conn)["sessions"]) == 1

      {_browser, _conn} =
        post(browser, "/admin/revoke-user-sessions", %{user_id: victim_user["id"]})

      assert signed_in_user(victim) == nil
      assert signed_in_user(other_device) == nil
    end
  end

  describe "impersonation" do
    test "an admin becomes the user, then themselves again", %{browser: browser} do
      {browser, admin} = sign_up_admin(browser)
      {_victim, victim_user} = new_user("grace@example.com")

      {browser, conn} = post(browser, "/admin/impersonate-user", %{user_id: victim_user["id"]})
      assert json(conn)["session"]["impersonated_by_id"] == admin["id"]

      expires_at = json(conn)["session"]["expires_at"] |> DateTime.from_iso8601() |> elem(1)
      assert DateTime.diff(expires_at, DateTime.utc_now()) in 590..600

      assert signed_in_user(browser)["email"] == "grace@example.com"

      {browser, conn} = post(browser, "/admin/stop-impersonating")
      assert json(conn)["user"]["email"] == "admin@example.com"
      assert signed_in_user(browser)["email"] == "admin@example.com"
    end

    test "other admins can't be impersonated without impersonate_admins", %{browser: browser} do
      {browser, _admin} = sign_up_admin(browser)
      {_other, other} = sign_up_admin(Browser.new(Auth), "boss@example.com")

      {_browser, conn} = post(browser, "/admin/impersonate-user", %{user_id: other["id"]})
      assert conn.status == 403
    end

    test "stop-impersonating needs an impersonation", %{browser: browser} do
      {browser, _admin} = sign_up_admin(browser)
      {_browser, conn} = post(browser, "/admin/stop-impersonating")
      assert json(conn)["error"]["code"] == "not_impersonating"
    end
  end

  test "has-permission checks the user's role, or another", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    {browser, conn} = post(browser, "/admin/has-permission", %{permissions: %{user: ["list"]}})
    assert json(conn) == %{"success" => false}

    {_browser, conn} =
      post(browser, "/admin/has-permission", %{permissions: %{user: ["list"]}, role: "admin"})

    assert json(conn) == %{"success" => true}
  end
end

defmodule Authmk.AdminAccessControlTest do
  # An app's own roles, including a support role with some admin actions.
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{Browser, Repo}

  alias Authmk.Plugins.Admin.Permissions, as: AdminPermissions

  defmodule Permissions do
    use Authmk.AccessControl,
      statements: AdminPermissions.statements() ++ [project: [:create]],
      roles: [
        admin: AdminPermissions.statements(),
        support: [user: [:list, :get], session: [:list]],
        member: [project: [:create]]
      ]
  end

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Admin, access_control: Permissions, default_role: "member"}
      ]
  end

  @moduletag auth: Auth

  test "custom roles decide, and the default role applies", %{browser: browser} do
    {browser, user} = sign_up(browser)
    assert user["role"] == "member"

    module = Authmk.Store.module(Authmk.Context.new(Auth.config()), :user)
    Repo.update_all(where(module, id: ^user["id"]), set: [role: "support"])

    {browser, conn} = get(browser, "/admin/list-users")
    assert json(conn)["total"] == 1

    {_other, other} = sign_up(Browser.new(Auth), %{email: "grace@example.com"})
    {browser, conn} = post(browser, "/admin/ban-user", %{user_id: other["id"]})
    assert conn.status == 403

    {_browser, conn} =
      post(browser, "/admin/has-permission", %{
        permissions: %{project: ["create"]},
        role: "member"
      })

    assert json(conn) == %{"success" => true}
  end
end
