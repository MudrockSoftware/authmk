defmodule Authmk.DashboardLicenceTest do
  # Runs as production would (Mix.env and AUTHMK_LICENCE_KEY are global):
  # one test at a time, after the async ones.
  use Authmk.EmulationCase, async: false

  import ExUnit.CaptureLog

  alias Authmk.Testing

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.Admin]
  end

  @moduletag auth: Auth

  setup do
    previous = System.get_env("AUTHMK_LICENCE_KEY")
    Mix.env(:prod)

    on_exit(fn ->
      Mix.env(:test)

      if previous,
        do: System.put_env("AUTHMK_LICENCE_KEY", previous),
        else: System.delete_env("AUTHMK_LICENCE_KEY")
    end)

    %{admin: Testing.create_user(Auth, email: "admin@example.com", role: "admin")}
  end

  defp dashboard(path, user) do
    conn = Plug.Test.conn(:get, "/admin" <> path) |> Testing.sign_in(Auth, user)
    Plug.forward(conn, tl(conn.path_info), Authmk.Dashboard, Authmk.Dashboard.init(auth: Auth))
  end

  test "without a valid key nothing is served, not even to admins", %{admin: admin} do
    for key <- [nil, "free-please"] do
      if key,
        do: System.put_env("AUTHMK_LICENCE_KEY", key),
        else: System.delete_env("AUTHMK_LICENCE_KEY")

      for path <- ["/", "/api/me", "/api/users", "/favicon.svg"] do
        log = capture_log(fn -> assert dashboard(path, admin).status == 403 end)
        assert log =~ "AUTHMK_LICENCE_KEY"
        refute key && log =~ key
      end
    end
  end

  test "with a valid key it opens", %{admin: admin} do
    System.put_env("AUTHMK_LICENCE_KEY", "authmk_" <> String.duplicate("a1", 12))
    assert dashboard("/", admin).status == 200

    assert JSON.decode!(dashboard("/api/me", admin).resp_body)["user"]["email"] ==
             "admin@example.com"
  end
end
