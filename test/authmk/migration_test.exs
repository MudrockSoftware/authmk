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
  # Extended, with `locale` changed from :string to :text.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword, Authmk.Test.GreetingPlugin],
    schema: [user: [additional_fields: [locale: [type: :text, default: "en"]]]],
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

    path = Database.new_path()
    on_exit(fn -> Database.delete!(path) end)
    repo = start_supervised!(Database.repo_child_spec(path))
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

  test "SQLite migrations can't change existing columns", %{dir: dir} do
    run_task(Extended, dir, "initial")

    assert_raise ArgumentError, ~r/SQLite can't change existing columns/, fn ->
      run_task(Authmk.MigrationTest.ChangedType, dir, "change", ["--allow-destructive"])
    end
  end

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

  defp tables do
    Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table'").rows |> List.flatten()
  end

  defp columns(table) do
    Repo.query!("SELECT name FROM pragma_table_info('#{table}')").rows |> List.flatten()
  end
end
