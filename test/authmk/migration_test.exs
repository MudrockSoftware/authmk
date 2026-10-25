defmodule Authmk.MigrationTest.Base do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000"
end

defmodule Authmk.MigrationTest.Extended do
  # The same app after enabling a plugin with a new table and adding a field.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword, Authmk.Test.GreetingPlugin],
    schema: [user: [additional_fields: [locale: [type: :string, default: "en"]]]],
    base_url: "http://localhost:4000"
end

defmodule Authmk.MigrationTest.RequiredField do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    schema: [user: [additional_fields: [plan: [type: :string, required: true]]]],
    base_url: "http://localhost:4000"
end

defmodule Authmk.MigrationTest.ChangedType do
  # Extended, with `locale` changed from a :string with a default to :text.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword, Authmk.Test.GreetingPlugin],
    schema: [user: [additional_fields: [locale: [type: :text]]]],
    base_url: "http://localhost:4000"
end

defmodule Authmk.MigrationTest.ValidatedExtended do
  # Extended's schema, checked against the database at startup.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword, Authmk.Test.GreetingPlugin],
    schema: [user: [additional_fields: [locale: [type: :string, default: "en"]]]],
    base_url: "http://localhost:4000",
    advanced: [validate_schema: true]
end

defmodule Authmk.MigrationTest.RenamedColumn do
  # Base, with user.name stored in a full_name column.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    schema: [user: [fields: [name: [source: :full_name]]]],
    base_url: "http://localhost:4000"
end

defmodule Authmk.MigrationTest.Prefixed do
  # Base, with every table prefixed.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    table_prefix: "auth_",
    base_url: "http://localhost:4000"
end

defmodule Authmk.MigrationTest do
  # Runs the real mix task, so it changes the global Mix shell: not async.
  use ExUnit.Case, async: false

  alias Authmk.Migration.Snapshot
  alias Authmk.MigrationTest.{Base, Extended, RequiredField}
  alias Authmk.Test.{Database, Repo}

  setup do
    dir = Path.join(System.tmp_dir!(), "authmk_migrations_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    database = Database.create!()
    on_exit(fn -> Database.delete!(database) end)
    repo = start_supervised!(Database.repo_child_spec(database))
    Repo.put_dynamic_repo(repo)

    %{dir: dir, repo: repo}
  end

  test "first run creates every table; a schema change adds only the difference", %{
    dir: dir,
    repo: repo
  } do
    run_task(Base, dir, "initial")
    run_task(Extended, dir, "add_greeting")

    assert [_initial, _add_greeting] = migration_files(dir)
    migrate!(dir, repo)

    assert "greeting_logs" in tables()
    assert "locale" in columns("users")
    assert "nickname" in columns("users")

    # Nothing changed since: no new migration, and --check passes.
    run_task(Extended, dir, "again")
    assert_received {:mix_shell, :info, ["No schema changes. Nothing to generate."]}
    run_task(Extended, dir, nil, ["--check"])
    assert length(migration_files(dir)) == 2
  end

  test "the generated migration can be rolled back", %{dir: dir, repo: repo} do
    run_task(Base, dir, "initial")
    run_task(Extended, dir, "add_greeting")
    migrations = migrate!(dir, repo)

    Ecto.Migrator.run(Repo, migrations, :down, step: 1, dynamic_repo: repo, log: false)

    refute "greeting_logs" in tables()
    refute "locale" in columns("users")
    assert "users" in tables()
  end

  test "--check fails when a migration is missing", %{dir: dir} do
    run_task(Base, dir, "initial")

    assert_raise Mix.Error, ~r/schema changed/, fn ->
      run_task(Extended, dir, nil, ["--check"])
    end
  end

  test "--baseline records existing tables without a migration", %{dir: dir} do
    run_task(Base, dir, nil, ["--baseline"])

    assert migration_files(dir) == []
    assert Snapshot.read(snapshot(dir)) == Authmk.Migration.current_snapshot(Base)
  end

  test "dropping tables needs --allow-destructive", %{dir: dir} do
    run_task(Extended, dir, "initial")

    assert_raise Mix.Error, ~r/--allow-destructive/, fn -> run_task(Base, dir, "shrink") end
    run_task(Base, dir, "shrink", ["--allow-destructive"])
    assert length(migration_files(dir)) == 2
  end

  test "a required field without a default can't be added to an existing table", %{dir: dir} do
    run_task(Base, dir, "initial")

    assert_raise ArgumentError, ~r/must be nullable or have a default/, fn ->
      run_task(RequiredField, dir, "add_plan")
    end
  end

  @tag :sqlite
  test "SQLite migrations can't change existing columns", %{dir: dir} do
    run_task(Extended, dir, "initial")

    assert_raise ArgumentError, ~r/SQLite can't change existing columns/, fn ->
      run_task(Authmk.MigrationTest.ChangedType, dir, "change", ["--allow-destructive"])
    end
  end

  @tag :server_database
  test "Postgres and MySQL migrations change column types, and roll back", %{dir: dir, repo: repo} do
    run_task(Extended, dir, "initial")
    run_task(Authmk.MigrationTest.ChangedType, dir, "change", ["--allow-destructive"])

    migrations = migrate!(dir, repo)
    assert "locale" in columns("users")

    Ecto.Migrator.run(Repo, migrations, :down, step: 1, dynamic_repo: repo, log: false)
    assert "locale" in columns("users")
  end

  test "the schema check names what a missing migration left out", %{dir: dir, repo: repo} do
    run_task(Base, dir, "initial")
    migrate!(dir, repo)

    assert {:error, message} = Authmk.SchemaCheck.run(Authmk.Config.load(Extended))
    assert message =~ "greeting_logs"
    assert message =~ "Run `mix authmk.gen.migration`"

    run_task(Extended, dir, "add_greeting")
    Ecto.Migrator.run(Repo, dir, :up, all: true, dynamic_repo: repo, log: false)
    assert :ok = Authmk.SchemaCheck.run(Authmk.Config.load(Extended))
  end

  test "with validate_schema, startup fails while a migration is missing", %{dir: dir} do
    # Startup runs in the auth module's own process, so it needs the named repo.
    database = Database.create!()
    on_exit(fn -> Database.delete!(database) end)

    named_repo =
      start_supervised!(Supervisor.child_spec({Repo, database: database}, id: :named_repo))

    run_task(Base, dir, "initial")
    Ecto.Migrator.run(Repo, dir, :up, all: true, dynamic_repo: named_repo, log: false)

    assert {:error, {{%ArgumentError{message: message}, _}, _}} =
             start_supervised(Authmk.MigrationTest.ValidatedExtended)

    assert message =~ "the database doesn't match the schema"
  end

  describe "renames" do
    setup %{dir: dir, repo: repo} do
      run_task(Base, dir, "initial")
      migrate!(dir, repo)

      user = Repo.insert!(%Base.User{name: "Ada", email: "ada@example.com"})
      Repo.insert!(%Base.Session{user_id: user.id, token: "hash", expires_at: DateTime.utc_now()})
      %{user: user}
    end

    test "a confirmed column rename keeps the data", %{dir: dir, repo: repo, user: user} do
      answer_yes(1)
      run_task(Authmk.MigrationTest.RenamedColumn, dir, "rename")
      assert_received {:mix_shell, :yes?, ["Was users.name renamed to full_name?"]}

      Ecto.Migrator.run(Repo, dir, :up, all: true, dynamic_repo: repo, log: false)
      assert Repo.get!(Authmk.MigrationTest.RenamedColumn.User, user.id).name == "Ada"

      Ecto.Migrator.run(Repo, dir, :down, step: 1, dynamic_repo: repo, log: false)
      assert Repo.get!(Base.User, user.id).name == "Ada"
    end

    test "confirmed table renames keep data, foreign keys and indexes", %{
      dir: dir,
      repo: repo,
      user: user
    } do
      answer_yes(4)
      run_task(Authmk.MigrationTest.Prefixed, dir, "prefix")
      assert_received {:mix_shell, :yes?, ["Was the table users renamed to auth_users?"]}

      Ecto.Migrator.run(Repo, dir, :up, all: true, dynamic_repo: repo, log: false)
      assert "auth_users" in tables()
      refute "users" in tables()
      assert [session] = Repo.all(Authmk.MigrationTest.Prefixed.Session) |> Repo.preload(:user)
      assert session.user.id == user.id

      # Nothing left to migrate: the renamed indexes match the new names.
      assert Authmk.Migration.changes(Authmk.MigrationTest.Prefixed, Snapshot.read(snapshot(dir))) ==
               []

      Ecto.Migrator.run(Repo, dir, :down, step: 1, dynamic_repo: repo, log: false)
      assert "users" in tables()
    end

    test "a declined rename is a drop and an add, which a required column can't be", %{dir: dir} do
      send(self(), {:mix_shell_input, :yes?, false})

      assert_raise ArgumentError, ~r/confirm the rename/, fn ->
        run_task(Authmk.MigrationTest.RenamedColumn, dir, "rename")
      end
    end

    test "declined table renames are drops, which need --allow-destructive", %{dir: dir} do
      for _ <- 1..4, do: send(self(), {:mix_shell_input, :yes?, false})

      assert_raise Mix.Error, ~r/--allow-destructive/, fn ->
        run_task(Authmk.MigrationTest.Prefixed, dir, "prefix")
      end
    end
  end

  defp answer_yes(count),
    do: for(_ <- 1..count, do: send(self(), {:mix_shell_input, :yes?, true}))

  defp run_task(auth, dir, name, extra \\ []) do
    # Unique names keep migration modules distinct across tests.
    name_args = if name, do: ["--name", "#{name}_#{System.unique_integer([:positive])}"], else: []

    Mix.Tasks.Authmk.Gen.Migration.run(
      ["--auth", inspect(auth), "--migrations-path", dir, "--snapshot-path", snapshot(dir)] ++
        name_args ++ extra
    )
  end

  defp snapshot(dir), do: Path.join(dir, "snapshot.json")

  defp migration_files(dir), do: dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort()

  # Compiles the generated files once and runs them. Returns `{version, module}` pairs.
  defp migrate!(dir, repo) do
    migrations =
      for file <- migration_files(dir) do
        {version, _rest} = file |> Path.basename() |> Integer.parse()
        [{module, _binary}] = Code.compile_file(file)
        {version, module}
      end

    Ecto.Migrator.run(Repo, migrations, :up, all: true, dynamic_repo: repo, log: false)
    migrations
  end

  defp tables, do: Database.tables()

  defp columns(table), do: Database.columns(table)
end
