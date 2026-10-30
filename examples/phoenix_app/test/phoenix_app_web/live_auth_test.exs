defmodule PhoenixAppWeb.LiveAuthTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Authmk.Testing

  # What the browser does with the page's form: post its fields to authmk.
  defp submit(conn, html, action, values) do
    form = html |> LazyHTML.from_document() |> LazyHTML.query("form[action='#{action}']")

    hidden =
      form
      |> LazyHTML.query("input[type=hidden]")
      |> Enum.map(&{hd(LazyHTML.attribute(&1, "name")), hd(LazyHTML.attribute(&1, "value"))})

    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("origin", "http://localhost:4000")
    |> dispatch(@endpoint, :post, action, URI.encode_query(hidden ++ Enum.to_list(values)))
  end

  test "sign in on the sign-in page, then the settings", %{conn: conn} do
    Testing.create_user(PhoenixApp.Auth,
      email: "ada@example.com",
      password: "correct horse battery"
    )

    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings")

    {:ok, _view, html} = live(conn, ~p"/sign-in")
    assert html =~ "data-authmk-passkey"

    wrong = submit(conn, html, "/auth/sign-in/email", email: "ada@example.com", password: "no")
    assert redirected_to(wrong, 303) == "/sign-in?error=invalid_credentials"
    {:ok, _view, html} = live(conn, "/sign-in?error=invalid_credentials")
    assert html =~ "Invalid email or password"

    ok =
      submit(conn, html, "/auth/sign-in/email",
        email: "ada@example.com",
        password: "correct horse battery"
      )

    assert redirected_to(ok, 303) == "/settings"

    {:ok, _view, html} = ok |> recycle() |> live(~p"/settings")
    assert html =~ "ada@example.com"

    # Signed in, the sign-in page sends you on.
    assert {:error, {:redirect, %{to: "/settings"}}} = ok |> recycle() |> live(~p"/sign-in")
  end

  test "settings: rename, sign out", %{conn: conn} do
    ada = Testing.create_user(PhoenixApp.Auth, email: "ada@example.com", name: "Ada")
    signed_in = Testing.sign_in(conn, PhoenixApp.Auth, ada)
    {:ok, _view, html} = live(signed_in, ~p"/settings")

    renamed = submit(signed_in, html, "/auth/update-user", name: "Ada Lovelace")
    assert redirected_to(renamed, 303) == "/settings"
    assert Testing.get_user_by(PhoenixApp.Auth, email: "ada@example.com").name == "Ada Lovelace"

    out = submit(signed_in, html, "/auth/sign-out", %{})
    assert redirected_to(out, 303) == "/"
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(signed_in, ~p"/settings")
  end

  test "admins only", %{conn: conn} do
    ada = Testing.create_user(PhoenixApp.Auth, email: "ada@example.com")
    boss = Testing.create_user(PhoenixApp.Auth, email: "boss@example.com", role: "admin")

    assert conn |> get(~p"/admin") |> redirected_to() == "/"

    assert conn |> Testing.sign_in(PhoenixApp.Auth, ada) |> get(~p"/admin") |> redirected_to() ==
             "/"

    assert conn |> Testing.sign_in(PhoenixApp.Auth, boss) |> get(~p"/admin") |> text_response(200) ==
             "Admins only"
  end

  test "the passkey script is served", %{conn: conn} do
    assert conn |> get("/auth/passkey.js") |> response(200) =~ "data-authmk-passkey"
  end
end
