defmodule Authmk.ServiceAccountExtrasTest do
  # Service accounts with OAuth client credentials, in the audit log, and
  # managed by admins.
  use Authmk.EmulationCase, async: true

  alias Authmk.Plug.{FetchSession, RequireAccessToken}
  alias Authmk.Plugins.AuditLog
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Admin,
        {Authmk.Plugins.APIKey, configurations: [default: [rate_limit: [enabled: false]]]},
        Authmk.Plugins.ServiceAccount,
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider, login_page: "/sign-in", consent_page: "/consent"},
        Authmk.Plugins.AuditLog
      ]
  end

  @moduletag auth: Auth

  defp create_account(browser, name \\ "Nightly export") do
    {browser, conn} = post(browser, "/service-account/create", %{name: name})
    {browser, json(conn)}
  end

  defp token(client_id, secret) do
    basic = "Basic " <> Base.encode64("#{client_id}:#{secret}")

    {_client, conn} =
      post(
        %{Browser.new(Auth) | origin: nil, headers: [{"authorization", basic}]},
        "/oauth2/token",
        %{grant_type: "client_credentials"}
      )

    {conn.status, json(conn)}
  end

  # The app's API, behind RequireAccessToken.
  defp api(access_token) do
    Plug.Test.conn(:get, "/reports")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> access_token)
    |> RequireAccessToken.call(RequireAccessToken.init(auth: Auth))
  end

  test "client credentials authenticate the service account, while it may be used", %{
    browser: browser
  } do
    {browser, _user} = sign_up(browser)
    {browser, account} = create_account(browser)

    {browser, conn} = post(browser, "/service-account/create-oauth-client", %{id: account["id"]})
    %{"client_id" => client_id, "client_secret" => secret} = json(conn)
    assert json(conn)["grant_types"] == ["client_credentials"]

    # One per service account.
    {browser, conn} = post(browser, "/service-account/create-oauth-client", %{id: account["id"]})
    assert json(conn)["error"]["code"] == "oauth_client_exists"

    {200, %{"access_token" => access_token}} = token(client_id, secret)
    conn = api(access_token)
    refute conn.halted
    assert conn.assigns.current_principal.name == "Nightly export"
    assert conn.assigns.current_user == nil

    # Disabled: its tokens stop working.
    {browser, _conn} =
      post(browser, "/service-account/update", %{id: account["id"], disabled: true})

    assert api(access_token).status == 401

    # Deleted: the client goes too.
    {_browser, _conn} = post(browser, "/service-account/delete", %{id: account["id"]})
    assert {401, %{"error" => "invalid_client"}} = token(client_id, secret)
  end

  test "a service account is the actor of what it does", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, account} = create_account(browser)
    {_browser, conn} = post(browser, "/service-account/create-key", %{id: account["id"]})

    # The app's API, called with the key, records what the account did.
    conn =
      Plug.Test.conn(:get, "/reports")
      |> Plug.Conn.put_req_header("x-api-key", json(conn)["key"])
      |> FetchSession.call(FetchSession.init(auth: Auth))

    :ok =
      AuditLog.log(Auth, "report.exported",
        actor: conn.assigns.current_principal,
        conn: conn,
        metadata: %{format: "csv"}
      )

    %{events: [event | _]} = AuditLog.list_events(Auth, event: "report.exported")
    assert event.actor_type == "service_account"
    assert event.actor_id == account["id"]
    assert event.metadata == %{"format" => "csv"}

    # Users' own actions say so.
    %{events: [created | _]} = AuditLog.list_events(Auth, event: "user.created")
    assert created.actor_type in [nil, "user"]
  end

  test "admins list, disable and delete every service account; others can't", %{
    browser: browser
  } do
    {owner, _user} = sign_up(browser, %{email: "owner@example.com"})
    {_owner, account} = create_account(owner)

    {anyone, conn} = get(owner, "/service-account/admin/list")
    assert json(conn)["error"]["code"] == "forbidden"
    _ = anyone

    Authmk.Testing.create_user(Auth,
      email: "admin@example.com",
      password: "correct horse battery",
      role: "admin"
    )

    {admin, _conn} =
      post(Browser.new(Auth), "/sign-in/email", %{
        email: "admin@example.com",
        password: "correct horse battery"
      })

    {admin, conn} = get(admin, "/service-account/admin/list")
    assert %{"total" => 1, "service_accounts" => [%{"name" => "Nightly export"}]} = json(conn)

    {admin, conn} =
      post(admin, "/service-account/admin/update", %{id: account["id"], disabled: true})

    assert json(conn)["disabled"] == true

    {_admin, conn} = post(admin, "/service-account/admin/delete", %{id: account["id"]})
    assert json(conn) == %{"success" => true}
    {_owner, conn} = get(owner, "/service-account/list")
    assert json(conn) == []
  end
end
