defmodule Authmk.ServiceAccountTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plug.{FetchSession, RequireAuthenticated}
  alias Authmk.Plugins.Admin.Permissions, as: AdminPermissions
  alias Authmk.Plugins.ServiceAccount
  alias Authmk.Test.{Browser, Repo}

  defmodule Permissions do
    use Authmk.AccessControl,
      statements: AdminPermissions.statements() ++ [reports: [:read, :write]],
      roles: [
        admin: AdminPermissions.statements() ++ [reports: [:read, :write]],
        user: [reports: [:read]],
        reader: [reports: [:read]]
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
        {Authmk.Plugins.Admin, access_control: Authmk.ServiceAccountTest.Permissions},
        {Authmk.Plugins.APIKey, configurations: [default: [rate_limit: [enabled: false]]]},
        {Authmk.Plugins.ServiceAccount, access_control: Authmk.ServiceAccountTest.Permissions}
      ]
  end

  @moduletag auth: Auth

  defp create(browser, params) do
    {browser, conn} = post(browser, "/service-account/create", params)
    {browser, json(conn)}
  end

  defp create_key(browser, service_account) do
    {browser, conn} =
      post(browser, "/service-account/create-key", %{id: service_account["id"], name: "deploy"})

    {browser, json(conn)}
  end

  # The app's own pipeline, with the key in the header.
  defp app_request(key, opts \\ []) do
    Plug.Test.conn(:get, "/reports")
    |> Plug.Conn.put_req_header("x-api-key", key)
    |> FetchSession.call(FetchSession.init(auth: Auth))
    |> RequireAuthenticated.call(RequireAuthenticated.init(opts))
  end

  test "a service account's key authenticates the account, never a user", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, account} = create(browser, %{name: "Nightly export", role: "reader"})
    assert account["role"] == "reader"
    {_browser, key} = create_key(browser, account)

    conn = app_request(key["key"], allow_principals: true)
    refute conn.halted
    assert conn.assigns.current_user == nil
    assert conn.assigns.current_principal.name == "Nightly export"

    # Routes for people turn it away.
    assert app_request(key["key"]).status == 401

    # And so do the auth endpoints that need a user.
    with_key = %{Browser.new(Auth) | headers: [{"x-api-key", key["key"]}]}

    {_with_key, conn} =
      post(with_key, "/change-password", %{current_password: "x", new_password: "y"})

    assert conn.status == 401
  end

  test "permissions come from the role", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, account} = create(browser, %{name: "Reports", role: "reader"})

    service_account =
      Repo.one(
        from(s in Authmk.Store.module(Authmk.Context.new(Auth.config()), :service_account))
      )

    assert ServiceAccount.has_permission?(Auth, service_account, %{reports: [:read]})
    refute ServiceAccount.has_permission?(Auth, service_account, %{reports: [:write]})
    assert account["role"] == "reader"
  end

  test "a service account can't get more than its creator may do", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, account} = create(browser, %{name: "Root", role: "admin"})
    assert account["error"]["code"] == "forbidden"
    {_browser, account} = create(browser, %{name: "Ghost", role: "emperor"})
    assert account["error"]["code"] == "invalid_role"
  end

  test "disabled and expired service accounts are refused", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, account} = create(browser, %{name: "Bot"})
    {browser, key} = create_key(browser, account)

    {browser, conn} =
      post(browser, "/service-account/update", %{id: account["id"], disabled: true})

    assert json(conn)["disabled"] == true
    assert app_request(key["key"], allow_principals: true).status == 401

    with_key = %{Browser.new(Auth) | headers: [{"x-api-key", key["key"]}]}
    {_with_key, conn} = get(with_key, "/get-session")
    assert json(conn)["error"]["code"] == "service_account_disabled"

    {browser, _conn} =
      post(browser, "/service-account/update", %{id: account["id"], disabled: false})

    refute app_request(key["key"], allow_principals: true).halted

    module = Authmk.Store.module(Authmk.Context.new(Auth.config()), :service_account)
    Repo.update_all(module, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])
    assert app_request(key["key"], allow_principals: true).status == 401
    _ = browser
  end

  test "allowed IPs, as addresses and ranges", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    {browser, account} = create(browser, %{name: "Bot", allowed_ips: ["300.1.1.1"]})
    assert account["error"]["code"] == "invalid_allowed_ips"

    {browser, account} =
      create(browser, %{name: "Office", allowed_ips: ["10.0.0.0/8", "2001:db8::/32"]})

    assert account["allowed_ips"] == ["10.0.0.0/8", "2001:db8::/32"]
    {browser, office_key} = create_key(browser, account)
    # Tests come from 127.0.0.1.
    assert app_request(office_key["key"], allow_principals: true).status == 401

    {browser, account} = create(browser, %{name: "Local", allowed_ips: ["127.0.0.0/8"]})
    {_browser, local_key} = create_key(browser, account)
    refute app_request(local_key["key"], allow_principals: true).halted
  end

  test "keys rotate without downtime", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, account} = create(browser, %{name: "Bot"})
    {browser, old} = create_key(browser, account)
    {browser, new} = create_key(browser, account)

    # Both work while callers switch over.
    refute app_request(old["key"], allow_principals: true).halted
    refute app_request(new["key"], allow_principals: true).halted

    {browser, conn} = get(browser, "/service-account/list-keys", %{id: account["id"]})
    assert length(json(conn)) == 2

    {_browser, conn} =
      post(browser, "/service-account/revoke-key", %{id: account["id"], key_id: old["id"]})

    assert json(conn) == %{"success" => true}
    assert app_request(old["key"], allow_principals: true).status == 401
    refute app_request(new["key"], allow_principals: true).halted
  end

  test "only the owner manages a service account", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, account} = create(browser, %{name: "Bot"})
    {_browser, key} = create_key(browser, account)
    {eve, _user} = sign_up(Browser.new(Auth), %{email: "eve@example.com"})

    for {method, path, params} <- [
          {:get, "/service-account/get", %{id: account["id"]}},
          {:post, "/service-account/update", %{id: account["id"], disabled: true}},
          {:post, "/service-account/create-key", %{id: account["id"]}},
          {:post, "/service-account/revoke-key", %{id: account["id"], key_id: key["id"]}},
          {:post, "/service-account/delete", %{id: account["id"]}}
        ] do
      {_eve, conn} = request(eve, method, path, params)
      assert json(conn)["error"]["code"] == "service_account_not_found", path
    end

    {eve, conn} = get(eve, "/service-account/list")
    assert json(conn) == []
    _ = eve
  end

  test "deleting a service account revokes its keys", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, account} = create(browser, %{name: "Bot"})
    {browser, key} = create_key(browser, account)

    {_browser, conn} = post(browser, "/service-account/delete", %{id: account["id"]})
    assert json(conn) == %{"success" => true}
    assert app_request(key["key"], allow_principals: true).status == 401
    assert Repo.aggregate("api_keys", :count) == 0
  end
end

defmodule Authmk.ServiceAccountOrganizationTest do
  use Authmk.EmulationCase, async: true

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
        {Authmk.Plugins.Organization, send_invitation_email: &__MODULE__.send_invitation/2},
        {Authmk.Plugins.APIKey, configurations: [default: [rate_limit: [enabled: false]]]},
        Authmk.Plugins.ServiceAccount
      ]

    def send_invitation(%{id: id}, _ctx), do: send(self(), {:invitation, id})
  end

  @moduletag auth: Auth

  test "an organization's service accounts, with its roles, gone with it", %{browser: _browser} do
    {owner, _user} = sign_up(Browser.new(Auth))
    {owner, conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})
    org = json(conn)

    {owner, _conn} =
      post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "admin"})

    assert_received {:invitation, id}
    {admin, _user} = sign_up(Browser.new(Auth), %{email: "grace@example.com"})
    {admin, _conn} = post(admin, "/organization/accept-invitation", %{invitation_id: id})

    # An admin can't make a service account an owner.
    {admin, conn} =
      post(admin, "/service-account/create", %{
        name: "CI",
        organization_id: org["id"],
        role: "owner"
      })

    assert json(conn)["error"]["code"] == "forbidden"

    {admin, conn} =
      post(admin, "/service-account/create", %{
        name: "CI",
        organization_id: org["id"],
        role: "member"
      })

    account = json(conn)
    assert account["organization_id"] == org["id"]
    assert account["user_id"] == nil
    {_admin, conn} = post(admin, "/service-account/create-key", %{id: account["id"]})
    assert json(conn)["key"]

    # It belongs to the organization, not to whoever made it.
    {admin, conn} = get(admin, "/service-account/list")
    assert json(conn) == []
    {_admin, conn} = get(admin, "/service-account/list", %{organization_id: org["id"]})
    assert [%{"name" => "CI"}] = json(conn)

    {_stranger, conn} =
      post(
        sign_up(Browser.new(Auth), %{email: "eve@example.com"}) |> elem(0),
        "/service-account/create",
        %{name: "x", organization_id: org["id"]}
      )

    assert json(conn)["error"]["code"] == "not_a_member"

    {_owner, _conn} = post(owner, "/organization/delete", %{organization_id: org["id"]})
    assert Repo.aggregate("service_accounts", :count) == 0
    assert Repo.aggregate("api_keys", :count) == 0
  end
end

defmodule Authmk.ServiceAccountIPTest do
  # Allow-lists against the address the request comes from (behind a proxy here).
  use Authmk.EmulationCase, async: true

  alias Authmk.Plug.{FetchSession, RequireAuthenticated}
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      advanced: [ip_address_headers: ["x-forwarded-for"]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.APIKey, configurations: [default: [rate_limit: [enabled: false]]]},
        Authmk.Plugins.ServiceAccount
      ]
  end

  @moduletag auth: Auth

  defp key_for(allowed_ips) do
    {browser, _user} =
      sign_up(Browser.new(Auth), %{email: "#{System.unique_integer([:positive])}@example.com"})

    {browser, conn} =
      post(browser, "/service-account/create", %{name: "Bot", allowed_ips: allowed_ips})

    {_browser, conn} = post(browser, "/service-account/create-key", %{id: json(conn)["id"]})
    json(conn)["key"]
  end

  defp from(key, ip) do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-api-key", key)
      |> Plug.Conn.put_req_header("x-forwarded-for", ip)
      |> FetchSession.call(FetchSession.init(auth: Auth))
      |> RequireAuthenticated.call(RequireAuthenticated.init(allow_principals: true))

    not conn.halted
  end

  test "IPv4 and IPv6 addresses and ranges", %{browser: _browser} do
    key = key_for(["192.168.1.10", "10.0.0.0/8", "2001:db8::/32", "::1"])

    assert from(key, "192.168.1.10")
    refute from(key, "192.168.1.11")
    assert from(key, "10.255.0.1")
    refute from(key, "11.0.0.1")
    assert from(key, "2001:db8:abcd::1")
    refute from(key, "2001:db9::1")
    assert from(key, "::1")
    refute from(key, "not an address")
  end

  test "everything with /0", %{browser: _browser} do
    key = key_for(["0.0.0.0/0"])
    assert from(key, "203.0.113.7")
    refute from(key, "2001:db8::1")
  end

  test "entries that aren't addresses or ranges are refused", %{browser: _browser} do
    {browser, _user} = sign_up(Browser.new(Auth))

    for bad <- [
          ["10.0.0.0/33"],
          ["10.0.0.0/-1"],
          ["10.0.0.0/x"],
          ["2001:db8::/129"],
          ["example.com"]
        ] do
      {_browser, conn} =
        post(browser, "/service-account/create", %{name: "Bot", allowed_ips: bad})

      assert json(conn)["error"]["code"] == "invalid_allowed_ips", inspect(bad)
    end
  end

  test "RequireAuthenticated also works called directly, with a path or nil", %{browser: _browser} do
    conn = FetchSession.call(Plug.Test.conn(:get, "/"), FetchSession.init(auth: Auth))
    assert RequireAuthenticated.call(conn, nil).status == 401
    assert RequireAuthenticated.call(conn, "/sign-in").status == 302
  end
end
