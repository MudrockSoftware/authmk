defmodule PlugApp.DashboardTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  alias Authmk.Testing

  test "admins get the dashboard and its API" do
    admin = Testing.create_user(PlugApp.Auth, email: "admin@example.com", role: "admin")
    page = conn(:get, "/admin/auth/") |> Testing.sign_in(PlugApp.Auth, admin) |> call()
    assert page.status == 200
    assert page.resp_body =~ "./_app/"

    overview =
      conn(:get, "/admin/auth/api/overview") |> Testing.sign_in(PlugApp.Auth, admin) |> call()

    assert json(overview)["totals"]["users"] == 1
  end

  test "everyone else is sent away" do
    user = Testing.create_user(PlugApp.Auth, email: "ada@example.com")
    page = conn(:get, "/admin/auth/") |> Testing.sign_in(PlugApp.Auth, user) |> call()
    assert get_resp_header(page, "location") == ["/"]
    assert get_path("/admin/auth/api/me").status == 401
  end
end
