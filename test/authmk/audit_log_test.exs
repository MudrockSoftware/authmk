defmodule Authmk.AuditLogTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plugins.AuditLog
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
        Authmk.Plugins.Organization,
        {Authmk.Plugins.AuditLog,
         can_view_all: &__MODULE__.admin?/1,
         destinations: [&__MODULE__.ship/1, &__MODULE__.broken/1]}
      ]

    def admin?(%{user: user}), do: user.email == "admin@example.com"
    def ship(event), do: send(self(), {:shipped, event.event})
    def broken(_event), do: raise("log pipeline down")
  end

  @moduletag auth: Auth

  defp events(browser) do
    {_browser, conn} = get(browser, "/audit-log/list", %{limit: 100})
    json(conn)["events"] |> Enum.map(& &1["event"])
  end

  test "a user's account history, with no secrets", %{browser: browser} do
    {browser, user} = sign_up(browser)

    {browser, _conn} =
      post(browser, "/change-password", %{
        current_password: "correct horse",
        new_password: "battery staple"
      })

    {browser, _conn} = post(browser, "/sign-out")

    {browser, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "battery staple"})

    names = events(browser)
    assert "user.created" in names
    assert "account.linked" in names
    assert "account.updated" in names
    assert "session.ended" in names
    assert Enum.count(names, &(&1 == "session.created")) >= 2

    {_browser, conn} = get(browser, "/audit-log/list", %{event: "account.linked"})

    assert [%{"metadata" => %{"provider_id" => "credential"}, "user_id" => user_id}] =
             json(conn)["events"]

    assert user_id == user["id"]

    # Nothing secret in any of it.
    stored = Repo.all(from(e in "audit_events", select: e.metadata)) |> Enum.join()
    refute stored =~ "battery"
    refute stored =~ "$argon2"

    assert_received {:shipped, "user.created"}
  end

  test "organization events, and everyone's log for admins only", %{browser: browser} do
    {admin, _user} = sign_up(browser, %{email: "admin@example.com"})
    {admin, conn} = post(admin, "/organization/create", %{name: "Acme", slug: "acme"})
    org_id = json(conn)["id"]

    {_other, _user} = sign_up(Browser.new(Auth), %{email: "bob@example.com"})

    {admin, conn} = get(admin, "/audit-log/list-all", %{organization_id: org_id})

    assert ["member.added", "organization.created"] =
             json(conn)["events"] |> Enum.map(& &1["event"]) |> Enum.sort()

    {_admin, conn} = get(admin, "/audit-log/list-all", %{event: "user.created"})
    assert json(conn)["total"] == 2

    {bob, _conn} =
      post(Browser.new(Auth), "/sign-in/email", %{
        email: "bob@example.com",
        password: "correct horse"
      })

    {_bob, conn} = get(bob, "/audit-log/list-all")
    assert conn.status == 403

    assert %{total: total} = AuditLog.list_events(Auth, user_id: nil)
    assert total > 4
  end

  test "old events go after the retention period", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    Repo.update_all("audit_events",
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -91 * 86_400)]
    )

    {_browser, _conn} = post(browser, "/sign-out")
    assert AuditLog.prune(Auth) > 0

    assert Repo.aggregate(from(e in "audit_events", where: e.event == "user.created"), :count) ==
             0
  end
end
