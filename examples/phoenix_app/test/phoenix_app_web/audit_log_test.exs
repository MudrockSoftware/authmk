defmodule PhoenixAppWeb.AuditLogTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  test "users see their own account history", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/sign-up/email", @user)

    events = conn |> recycle() |> get("/auth/audit-log/list") |> json_response(200)
    assert "user.created" in Enum.map(events["events"], & &1["event"])

    assert conn |> recycle() |> get("/auth/audit-log/list-all") |> json_response(403)
  end
end
