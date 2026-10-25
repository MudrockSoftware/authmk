defmodule Authmk.InstallTest do
  # Runs the installer on simulated projects, the way `mix igniter.install authmk` would.
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "Phoenix app" do
    setup do
      %{
        igniter: phx_test_project(app_name: :my_app) |> Igniter.compose_task("authmk.install", [])
      }
    end

    test "creates the auth module, sending email through the app's mailer", %{igniter: igniter} do
      igniter
      |> assert_creates("lib/my_app/auth.ex")
      |> assert_content_includes("lib/my_app/auth.ex", "repo: MyApp.Repo")
      |> assert_content_includes("lib/my_app/auth.ex", "|> MyApp.Mailer.deliver()")
    end

    test "starts it after the repo", %{igniter: igniter} do
      assert_has_patch(igniter, "lib/my_app/application.ex", """
         |      MyApp.Repo,
      + |      MyApp.Auth,
      """)
    end

    test "mounts it and loads the user in the browser pipeline", %{igniter: igniter} do
      igniter
      |> assert_content_includes("lib/my_app_web/router.ex", ~s|forward("/auth", MyApp.Auth)|)
      |> assert_content_includes(
        "lib/my_app_web/router.ex",
        "plug(Authmk.Plug.FetchSession, auth: MyApp.Auth)"
      )
    end

    test "configures secrets per environment, and production from the environment", %{
      igniter: igniter
    } do
      igniter
      |> assert_content_includes("config/dev.exs", "config :my_app, MyApp.Auth, secret: ")
      |> assert_content_includes("config/test.exs", "background: :inline")
      |> assert_content_includes(
        "config/runtime.exs",
        ~s|base_url: System.fetch_env!("AUTHMK_BASE_URL")|
      )

      dev = file_content(igniter, "config/dev.exs")
      test = file_content(igniter, "config/test.exs")
      [dev_secret] = Regex.run(~r/secret: "([^"]+)"/, dev, capture: :all_but_first)
      [test_secret] = Regex.run(~r/secret: "([^"]+)"/, test, capture: :all_but_first)
      assert byte_size(dev_secret) >= 32 and dev_secret != test_secret
    end

    test "generates the migration", %{igniter: igniter} do
      assert {"authmk.gen.migration", []} in igniter.tasks
    end

    test "running it again changes nothing", %{igniter: igniter} do
      igniter
      |> apply_igniter!()
      |> Igniter.compose_task("authmk.install", [])
      |> assert_unchanged()
    end
  end

  test "a Plug.Router app gets the forward after plug :dispatch" do
    test_project(
      app_name: :shop,
      files: %{
        "lib/shop/repo.ex" => """
        defmodule Shop.Repo do
          use Ecto.Repo, otp_app: :shop, adapter: Ecto.Adapters.SQLite3
        end
        """,
        "lib/shop/router.ex" => """
        defmodule Shop.Router do
          use Plug.Router

          plug :match
          plug :dispatch

          get "/" do
            send_resp(conn, 200, "ok")
          end
        end
        """
      }
    )
    |> Igniter.compose_task("authmk.install", [])
    |> assert_content_includes(
      "lib/shop/router.ex",
      ~s|plug(:dispatch)\n\n  forward("/auth", to: Shop.Auth)|
    )
    |> assert_content_includes("lib/shop/auth.ex", "authmk logs a warning instead")
  end

  test "an app without a repo is told what to do" do
    igniter = test_project(app_name: :norepo) |> Igniter.compose_task("authmk.install", [])
    assert Enum.any?(igniter.issues, &(&1 =~ "authmk needs an Ecto repo"))
  end

  defp assert_content_includes(igniter, path, text) do
    assert file_content(igniter, path) =~ text, "expected #{path} to include #{inspect(text)}"
    igniter
  end

  defp file_content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end
end
