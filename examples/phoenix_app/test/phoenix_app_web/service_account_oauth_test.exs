defmodule PhoenixAppWeb.ServiceAccountOAuthTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

  test "a service account calls the API with OAuth client credentials", %{conn: conn} do
    owner =
      conn
      |> from_browser()
      |> post("/auth/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse battery",
        name: "Ada"
      })

    account =
      owner
      |> recycle()
      |> from_browser()
      |> post("/auth/service-account/create", %{name: "Nightly export"})

    client =
      owner
      |> recycle()
      |> from_browser()
      |> post("/auth/service-account/create-oauth-client", %{
        id: json_response(account, 200)["id"],
        scope: "profile"
      })

    %{"client_id" => client_id, "client_secret" => secret} = json_response(client, 200)

    token =
      build_conn()
      |> put_req_header("authorization", "Basic " <> Base.encode64("#{client_id}:#{secret}"))
      |> post("/auth/oauth2/token", %{grant_type: "client_credentials", scope: "profile"})

    profile =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> json_response(token, 200)["access_token"])
      |> get("/api/profile")

    assert json_response(profile, 200) == %{"name" => "Nightly export"}
  end

  test "mix authmk.create_admin makes the first admin", %{conn: conn} do
    System.put_env("AUTHMK_ADMIN_PASSWORD", "correct horse battery")
    on_exit(fn -> System.delete_env("AUTHMK_ADMIN_PASSWORD") end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Authmk.CreateAdmin.run(["boss@example.com", "--name", "Boss"])
    assert_received {:mix_shell, :info, ["Created admin boss@example.com."]}

    signed_in =
      conn
      |> from_browser()
      |> post("/auth/sign-in/email", %{
        email: "boss@example.com",
        password: "correct horse battery"
      })

    assert signed_in |> recycle() |> get(~p"/admin") |> text_response(200) == "Admins only"
  end
end
