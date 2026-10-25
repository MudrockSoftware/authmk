defmodule Authmk.Test.Database do
  @moduledoc false
  # A new SQLite database per test, migrated with the migration authmk
  # generates for the auth module.

  alias Authmk.Migration
  alias Authmk.Migration.Snapshot
  alias Authmk.Test.Repo

  @doc "A unique database file path."
  def new_path do
    Path.join(System.tmp_dir!(), "authmk_test_#{System.unique_integer([:positive])}.db")
  end

  @doc "Child spec of a repo instance on `path`."
  def repo_child_spec(path) do
    Supervisor.child_spec({Repo, name: nil, database: path}, id: {Repo, path})
  end

  @doc "Runs the generated migration for `auth` on the repo instance `pid`."
  def migrate!(auth, pid) do
    migration = migration_module(auth)
    Ecto.Migrator.run(Repo, [{1, migration}], :up, all: true, dynamic_repo: pid, log: false)
  end

  @doc "Deletes a database file and its SQLite side files."
  def delete!(path) do
    for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    :ok
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
