defmodule PhoenixAppWeb.OrganizationTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  defp sign_up(conn, email) do
    conn
    |> from_browser()
    |> post("/auth/sign-up/email", %{email: email, password: "correct horse", name: "User"})
  end

  test "create an organization, invite someone by email, and they join", %{conn: conn} do
    owner = sign_up(conn, "ada@example.com")

    owner =
      owner
      |> recycle()
      |> from_browser()
      |> post("/auth/organization/create", %{name: "Acme", slug: "acme"})

    owner
    |> recycle()
    |> from_browser()
    |> post("/auth/organization/invite-member", %{email: "grace@example.com", role: "admin"})

    assert_email_sent(fn email ->
      [_, id] = Regex.run(~r/invitation id is ([\w-]+)/, email.text_body)
      send(self(), {:invitation, id})
    end)

    assert_received {:invitation, id}

    grace =
      build_conn()
      |> sign_up("grace@example.com")
      |> recycle()
      |> from_browser()
      |> post("/auth/organization/accept-invitation", %{invitation_id: id})

    assert json_response(grace, 200)["member"]["role"] == "admin"

    conn = grace |> recycle() |> get("/auth/organization/get-active-member-role")
    assert json_response(conn, 200) == %{"role" => "admin"}
  end
end
