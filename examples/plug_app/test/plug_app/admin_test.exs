defmodule PlugApp.AdminTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  import Ecto.Query

  defp sign_up(email) do
    conn =
      post_json("/auth/sign-up/email", %{email: email, password: "correct horse", name: "User"})

    {cookies(conn), json(conn)["user"]}
  end

  test "an admin lists and bans users" do
    {admin, admin_user} = sign_up("admin@example.com")
    # The first admin is set up by the app, here directly in the database.
    PlugApp.Repo.update_all(where(PlugApp.Auth.User, id: ^admin_user["id"]), set: [role: "admin"])
    {_user, user} = sign_up("ada@example.com")

    conn = get_path("/auth/admin/list-users?search_value=ada", admin)
    assert [%{"email" => "ada@example.com"}] = json(conn)["users"]

    conn = post_json("/auth/admin/ban-user", %{user_id: user["id"], ban_reason: "Spam"}, admin)
    assert json(conn)["user"]["banned"] == true

    conn =
      post_json("/auth/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert json(conn)["error"]["code"] == "banned"
  end
end
