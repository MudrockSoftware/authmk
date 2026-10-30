defmodule PlugApp.AuditLogTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  @user %{email: "ada@example.com", password: "correct horse", name: "Ada"}

  test "users see their own account history" do
    session = cookies(post_json("/auth/sign-up/email", @user))
    events = json(get_path("/auth/audit-log/list", session))["events"] |> Enum.map(& &1["event"])

    assert "user.created" in events
    assert "session.created" in events

    # Everyone's log is for admins.
    assert get_path("/auth/audit-log/list-all", session).status == 403
  end
end
