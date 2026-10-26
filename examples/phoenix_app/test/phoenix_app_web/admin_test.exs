defmodule PhoenixAppWeb.AdminTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  import Ecto.Query

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "an admin impersonates a user, then stops", %{conn: conn} do
    user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}

    ada =
      build_conn() |> from_browser() |> post("/auth/sign-up/email", user) |> json_response(200)

    admin = %{email: "admin@example.com", password: "correct horse", name: "Root"}
    conn = conn |> from_browser() |> post("/auth/sign-up/email", admin)
    admin_id = json_response(conn, 200)["user"]["id"]
    # The first admin is set up by the app, here directly in the database.
    PhoenixApp.Repo.update_all(where(PhoenixApp.Auth.User, id: ^admin_id), set: [role: "admin"])

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/admin/impersonate-user", %{user_id: ada["user"]["id"]})

    assert json_response(conn, 200)["user"]["email"] == "ada@example.com"

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Signed in as ada@example.com"

    conn = conn |> recycle() |> from_browser() |> post("/auth/admin/stop-impersonating")
    assert json_response(conn, 200)["user"]["email"] == "admin@example.com"

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Signed in as admin@example.com"
  end
end
