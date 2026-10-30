defmodule Authmk.BackgroundObanTest do
  # Background work as Oban jobs: enqueued, kept encrypted, run later.
  use Authmk.EmulationCase, async: true

  alias Authmk.Background.ObanWorker
  alias Authmk.Test.Repo

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: {:oban, name: Authmk.BackgroundObanTest.Oban, queue: :mailers},
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.MagicLink, send_magic_link: &__MODULE__.send_magic_link/2}
      ]

    # Jobs run in the test process here (Oban.Testing).
    def send_magic_link(link, ctx), do: send(self(), {:magic_link, link, ctx})
  end

  defmodule ObanTables do
    use Ecto.Migration
    def up, do: Oban.Migrations.up()
    def down, do: Oban.Migrations.down()
  end

  @moduletag auth: Auth

  # Oban's MySQL migrations look tables up by the repo's configured
  # `:database`, and these tests give each case a database of its own.
  if Repo.__adapter__() == Ecto.Adapters.MyXQL,
    do: @moduletag(skip: "Oban's MySQL migrations need a static :database")

  setup %{repo: repo} do
    Ecto.Migrator.run(Repo, [{2, ObanTables}], :up, all: true, dynamic_repo: repo, log: false)

    # Started from the test process: Oban checks its tables as it starts,
    # through this test's own repo.
    {:ok, oban} =
      Oban.start_link(
        name: Authmk.BackgroundObanTest.Oban,
        repo: Repo,
        engine: engine(),
        prefix: prefix(),
        get_dynamic_repo: fn -> repo end,
        testing: :manual
      )

    on_exit(fn -> if Process.alive?(oban), do: Supervisor.stop(oban) end)

    :ok
  end

  defp jobs, do: Oban.Testing.all_enqueued(Repo, worker: ObanWorker, prefix: prefix())

  # Each database has its own Oban engine; only PostgreSQL has schemas.
  defp engine do
    case Repo.__adapter__() do
      Ecto.Adapters.SQLite3 -> Oban.Engines.Lite
      Ecto.Adapters.Postgres -> Oban.Engines.Basic
    end
  end

  defp prefix, do: if(Repo.__adapter__() == Ecto.Adapters.Postgres, do: "public", else: false)

  test "a magic link waits as a job, encrypted, and works once it runs", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, conn} = post(browser, "/sign-in/magic-link", %{email: "ada@example.com"})
    assert json(conn) == %{"status" => true}

    # Not sent yet: queued.
    refute_received {:magic_link, _link, _ctx}
    assert [%Oban.Job{queue: "mailers", args: args, max_attempts: 5}] = jobs()

    # The link's token isn't readable in the jobs table.
    refute inspect(args) =~ "magic-link/verify"
    refute args["job"] =~ "ada@example.com"

    assert :ok = Oban.Testing.perform_job(ObanWorker, args, repo: Repo)
    assert_received {:magic_link, %{url: url, email: "ada@example.com"}, ctx}

    # The callback's context: the config and base URL, not the request.
    assert ctx.base_url == "http://localhost:4000"
    assert ctx.conn == nil

    %URI{path: "/auth" <> path, query: query} = URI.parse(url)
    {_browser, conn} = get(browser, path, URI.decode_query(query))
    assert conn.status == 200
    assert json(conn)["user"]["email"] == "ada@example.com"
  end

  test "a job that doesn't decrypt is cancelled, not retried" do
    args = %{"auth" => inspect(Auth), "base_url" => "http://localhost:4000", "job" => "forged"}
    assert {:cancel, :undecryptable} = Oban.Testing.perform_job(ObanWorker, args, repo: Repo)
  end
end
