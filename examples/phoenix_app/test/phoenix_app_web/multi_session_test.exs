defmodule PhoenixAppWeb.MultiSessionTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  defp sign_in(conn, email) do
    conn
    |> recycle()
    |> from_browser()
    |> post("/auth/sign-in/email", %{email: email, password: "correct horse"})
  end

  test "two accounts on one device, and switching between them", %{conn: conn} do
    for email <- ["ada@example.com", "grace@example.com"] do
      build_conn()
      |> from_browser()
      |> post("/auth/sign-up/email", %{email: email, password: "correct horse", name: email})
    end

    conn = conn |> sign_in("ada@example.com") |> sign_in("grace@example.com")

    assert conn |> recycle() |> get(~p"/") |> html_response(200) =~
             "Signed in as grace@example.com"

    sessions =
      conn |> recycle() |> get("/auth/multi-session/list-device-sessions") |> json_response(200)

    ada = Enum.find(sessions, &(&1["user"]["email"] == "ada@example.com"))["session"]["id"]

    conn =
      conn
      |> recycle()
      |> from_browser()
      |> post("/auth/multi-session/set-active", %{session_id: ada})

    assert conn |> recycle() |> get(~p"/") |> html_response(200) =~ "Signed in as ada@example.com"
  end
end
