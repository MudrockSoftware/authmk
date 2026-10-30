defmodule Authmk.Test.Database do
  @moduledoc false
  # A new database per test, migrated with the migration authmk generates
  # for the auth module. SQLite files by default; Postgres or MySQL
  # databases with AUTHMK_TEST_DB.

  alias Authmk.Migration
  alias Authmk.Migration.Snapshot
  alias Authmk.Test.Repo

  @doc "Which database the tests run on: :sqlite, :postgres or :mysql."
  def kind, do: Migration.adapter(Repo)

  @doc "Creates a new, empty database and returns its name (a file path for SQLite)."
  def create! do
    case kind() do
      :sqlite ->
        Path.join(System.tmp_dir!(), "authmk_test_#{System.unique_integer([:positive])}.db")

      _server ->
        name = "authmk_test_#{System.unique_integer([:positive])}"
        :ok = Repo.__adapter__().storage_up(Keyword.put(Repo.config(), :database, name))
        name
    end
  end

  @doc "Child spec of a repo instance on `database`."
  def repo_child_spec(database, name \\ nil) do
    Supervisor.child_spec({Repo, name: name, database: database}, id: {Repo, database})
  end

  @doc "Runs the generated migration for `auth` on the repo instance `pid`."
  def migrate!(auth, pid) do
    migration = migration_module(auth)
    Ecto.Migrator.run(Repo, [{1, migration}], :up, all: true, dynamic_repo: pid, log: false)
  end

  @doc "Drops a database."
  def delete!(database) do
    case kind() do
      :sqlite -> for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
      _server -> Repo.__adapter__().storage_down(Keyword.put(Repo.config(), :database, database))
    end

    :ok
  end

  @doc "Table names in the current database."
  def tables do
    sql =
      case kind() do
        :sqlite ->
          "SELECT name FROM sqlite_master WHERE type = 'table'"

        :postgres ->
          "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"

        :mysql ->
          "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()"
      end

    Repo.query!(sql).rows |> List.flatten()
  end

  @doc "Column names of a table in the current database."
  def columns(table) do
    {sql, params} =
      case kind() do
        :sqlite ->
          {"SELECT name FROM pragma_table_info(?)", [table]}

        :postgres ->
          {"SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1",
           [table]}

        :mysql ->
          {"SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ?",
           [table]}
      end

    Repo.query!(sql, params).rows |> List.flatten()
  end

  # Generated once per auth module, then reused by every test.
  defp migration_module(auth) do
    key = {__MODULE__, auth}

    case :persistent_term.get(key, nil) do
      nil ->
        name = "Authmk.Test.Migrations.M#{System.unique_integer([:positive])}"
        source = Migration.render(auth, Snapshot.empty(), name)
        [{module, _binary}] = Code.compile_string(source)
        :persistent_term.put(key, module)
        module

      module ->
        module
    end
  end
end
