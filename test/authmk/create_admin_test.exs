defmodule Authmk.CreateAdminTest do
  # The task prints through the global Mix shell and reads an environment
  # variable: not async.
  use Authmk.EmulationCase, async: false

  alias Authmk.Test.Browser
  alias Mix.Tasks.Authmk.CreateAdmin

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
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    on_exit(fn -> System.delete_env("AUTHMK_ADMIN_PASSWORD") end)
    :ok
  end

  defp output do
    assert_received {:mix_shell, :info, [line]}
    line
  end

  test "creates an admin who signs in with the password from the environment", %{
    browser: browser
  } do
    System.put_env("AUTHMK_ADMIN_PASSWORD", "correct horse battery")
    CreateAdmin.run(["ada@example.com", "--name", "Ada", "--auth", inspect(Auth)])
    assert output() == "Created admin ada@example.com."

    {browser, conn} =
      post(browser, "/sign-in/email", %{
        email: "ada@example.com",
        password: "correct horse battery"
      })

    assert json(conn)["user"]["role"] == "admin"
    assert json(conn)["user"]["email_verified"]

    # An admin: the Admin plugin's endpoints answer.
    {_browser, conn} = get(browser, "/admin/list-users")
    assert json(conn)["total"] == 1
  end

  test "makes an existing user an admin, keeping their password and roles", %{browser: browser} do
    {_browser, _user} =
      sign_up(browser, %{email: "grace@example.com", password: "her own password"})

    System.put_env("AUTHMK_ADMIN_PASSWORD", "not used for existing users")

    CreateAdmin.run(["grace@example.com", "--auth", inspect(Auth)])
    assert output() == "grace@example.com is an admin now (role: user,admin)."

    CreateAdmin.run(["grace@example.com", "--auth", inspect(Auth)])
    assert output() == "grace@example.com is already an admin."

    {_browser, conn} =
      post(Browser.new(Auth), "/sign-in/email", %{
        email: "grace@example.com",
        password: "her own password"
      })

    assert conn.status == 200
  end

  test "without a password, or with bad input" do
    CreateAdmin.run(["root@example.com", "--auth", inspect(Auth)])
    assert output() == "Created admin root@example.com."
    assert output() =~ "No password set"

    System.put_env("AUTHMK_ADMIN_PASSWORD", "short")

    assert_raise Mix.Error, ~r/Couldn't create the admin/, fn ->
      CreateAdmin.run(["x@example.com", "--auth", inspect(Auth)])
    end

    assert_raise Mix.Error, ~r/Couldn't create the admin/, fn ->
      CreateAdmin.run(["not an email", "--auth", inspect(Auth)])
    end

    assert_raise Mix.Error, ~r/Usage/, fn -> CreateAdmin.run([]) end
  end
end
