defmodule Authmk.DashboardAnalyticsTest do
  # Analytics from real sign-ups, sign-ins and failed sign-ins, by date
  # range and organization, and the CSV exports.
  use Authmk.EmulationCase, async: true

  import Authmk.Test.DashboardHelpers

  alias Authmk.{Context, Store, Testing}
  alias Authmk.Plugins.Organization
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
        Authmk.Plugins.TwoFactor,
        Authmk.Plugins.Organization,
        Authmk.Plugins.AuditLog
      ]
  end

  defmodule WithoutAuditLog do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.Admin]
  end

  @moduletag auth: Auth

  setup %{auth: auth, browser: browser} do
    if auth == Auth, do: sign_ups_and_sign_ins(browser), else: :ok
  end

  defp sign_ups_and_sign_ins(browser) do
    {_browser, ada} = sign_up(browser, %{email: "ada@example.com", name: "=cmd|' /C calc'!A0"})
    sign_up(Browser.new(Auth), %{email: "grace@example.com", name: "Grace"})

    for password <- ["wrong horse", "correct horse"] do
      Browser.post(Browser.new(Auth), "/sign-in/email", %{
        email: "ada@example.com",
        password: password
      })
    end

    %{
      admin: Testing.create_user(Auth, email: "admin@example.com", role: "admin"),
      ada: Testing.get_user_by(Auth, id: ada["id"])
    }
  end

  test "sign-ups, sign-ins, active users, failures and adoption", %{admin: admin} do
    today = Date.to_iso8601(Date.utc_today())
    {200, report} = get_json(Auth, "analytics", admin)

    assert report["source"] == "audit_log"
    assert length(report["sign_ups"]) == 30
    assert %{"day" => ^today, "count" => 3} = List.last(report["sign_ups"])
    # Two sign-ups that signed in, Ada again, and the admin (signed in by the test).
    assert List.last(report["sign_ins"])["count"] == 4
    assert List.last(report["active_users"])["count"] == 3
    assert List.last(report["failed_sign_ins"])["count"] == 1
    assert %{"method" => "email", "count" => 3} in report["sign_ins_by_method"]
    assert %{"method" => "email", "count" => 2} in report["sign_ups_by_method"]
    assert [%{"code" => "invalid_credentials", "count" => 1}] = report["failure_reasons"]

    assert %{"users" => 3, "verified_email" => 1, "two_factor" => 0, "passkey" => nil} =
             report["adoption"]
  end

  test "a date range and an organization", %{admin: admin, ada: ada} do
    yesterday = Date.add(Date.utc_today(), -1) |> Date.to_iso8601()
    {200, report} = get_json(Auth, "analytics?from=#{yesterday}&to=#{yesterday}", admin)
    assert [%{"day" => ^yesterday, "count" => 0}] = report["sign_ups"]

    assert {400, %{"error" => %{"code" => "invalid_range"}}} =
             get_json(Auth, "analytics?from=2020-01-01&to=2026-01-01", admin)

    assert {400, _} = get_json(Auth, "analytics?from=yesterday", admin)

    ctx = Context.new(Auth.config())
    {:ok, acme} = Store.insert(ctx, :organization, %{name: "Acme", slug: "acme"})
    {:ok, _member} = Organization.add_member(Auth, acme.id, ada.id, "owner")

    {200, report} = get_json(Auth, "analytics?organization_id=#{acme.id}", admin)
    assert List.last(report["sign_ups"])["count"] == 1
    assert List.last(report["sign_ins"])["count"] == 2
    assert List.last(report["active_users"])["count"] == 1
    # Failed sign-ins aren't anyone's yet.
    assert report["failed_sign_ins"] == nil
    assert report["adoption"]["users"] == 1
  end

  test "exports, safe to open in a spreadsheet, and audited", %{admin: admin} do
    conn = api(Auth, :get, "exports/users.csv", admin)
    assert conn.status == 200
    assert ["text/csv" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/attachment; filename="users-\d{4}-\d{2}-\d{2}\.csv"/

    [header | rows] = String.split(conn.resp_body, "\r\n", trim: true)
    assert header == "id,email,name,email_verified,role,banned,two_factor_enabled,created_at"
    assert length(rows) == 3
    # A formula stays text.
    assert Enum.any?(rows, &(&1 =~ ",'=cmd|' /C calc'!A0,"))

    conn = api(Auth, :get, "exports/users.csv?search=grace", admin)
    assert length(String.split(conn.resp_body, "\r\n", trim: true)) == 2

    conn = api(Auth, :get, "exports/events.csv?event=sign_in.failed", admin)
    assert [_header, row] = String.split(conn.resp_body, "\r\n", trim: true)
    assert row =~ "sign_in.failed"

    conn = api(Auth, :get, "exports/analytics.csv", admin)
    [header | days] = String.split(conn.resp_body, "\r\n", trim: true)
    assert header == "day,sign_ups,sign_ins,active_users,failed_sign_ins"

    today = Date.to_iso8601(Date.utc_today())
    assert [^today, "3", _sign_ins, _active, "1"] = String.split(List.last(days), ",")

    assert api(Auth, :get, "exports/secrets.csv", admin).status == 404

    events = Enum.map(dashboard_events(Auth), & &1.event)
    assert "dashboard.export.users" in events
    assert "dashboard.export.events" in events
  end

  @tag auth: WithoutAuditLog
  test "without the audit log, sign-ins come from sessions" do
    admin = Testing.create_user(WithoutAuditLog, email: "admin@example.com", role: "admin")
    Testing.create_session(WithoutAuditLog, admin)

    {200, report} = get_json(WithoutAuditLog, "analytics", admin)
    assert report["source"] == "sessions"
    # Ours, and the one the test signs the admin in with.
    assert List.last(report["sign_ins"])["count"] == 2
    assert report["sign_ins_by_method"] == nil
    assert report["failed_sign_ins"] == nil

    assert {400, _} =
             get_json(WithoutAuditLog, "exports/events.csv", admin)
             |> then(fn {status, _body} -> {status, nil} end)
  end
end
