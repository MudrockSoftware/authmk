defmodule Mix.Tasks.Authmk.Gen.Migration do
  @shortdoc "Generates a migration for authmk schema changes"

  @moduledoc """
  Generates an Ecto migration for whatever changed in your auth module's
  schema since the last run.

      mix authmk.gen.migration

  It compares the schema with the snapshot in `priv/repo/authmk/` and writes
  a migration to `priv/repo/migrations/`, then updates the snapshot. Commit
  both. Run the migration with `mix ecto.migrate`.

  ## Options

    * `--auth MyApp.Auth` - the auth module. Needed when the app has several.
    * `--baseline` - record the current schema as already migrated, without
      writing a migration. Use it when adopting authmk on existing tables.
    * `--check` - write nothing; exit with an error if a migration is missing.
      Use it in CI.
    * `--allow-destructive` - allow migrations that drop tables or columns,
      or change columns.

  When a table or column seems to have been renamed (one disappeared and an
  identical one appeared), the task asks whether it was a rename, so the
  data is kept instead of dropped.
    * `--name NAME` - migration name (default `authmk`).
    * `--migrations-path PATH`, `--snapshot-path PATH` - override where files go.
  """

  use Mix.Task

  alias Authmk.Migration
  alias Authmk.Migration.{Diff, Renames, Snapshot}

  @switches [
    auth: :string,
    baseline: :boolean,
    check: :boolean,
    allow_destructive: :boolean,
    name: :string,
    migrations_path: :string,
    snapshot_path: :string
  ]

  # Ecto migration macros, written without parentheses like Ecto's own docs.
  @migration_locals [
    add: 2,
    add: 3,
    create: 1,
    drop: 1,
    modify: 3,
    remove: 1,
    timestamps: 1
  ]

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("compile", [])
    Mix.Task.run("app.config", [])

    auth = Mix.Authmk.auth_module(opts[:auth])
    repo = auth.__authmk__(:compile_options)[:repo]
    snapshot_path = opts[:snapshot_path] || Mix.Authmk.snapshot_path(repo, auth)
    snapshot = Snapshot.read(snapshot_path)
    ops = Migration.changes(auth, snapshot)

    cond do
      opts[:check] -> check(ops)
      opts[:baseline] -> baseline(auth, snapshot_path)
      ops == [] -> Mix.shell().info("No schema changes. Nothing to generate.")
      true -> generate(auth, repo, snapshot, snapshot_path, confirm_renames(auth, snapshot), opts)
    end
  end

  # Asks about likely table renames, then column renames given those.
  defp confirm_renames(auth, snapshot) do
    current = Migration.current_snapshot(auth)

    tables =
      Enum.filter(Renames.table_candidates(snapshot, current), fn {:table, from, to} ->
        Mix.shell().yes?("Was the table #{from} renamed to #{to}?")
      end)

    columns =
      snapshot
      |> Renames.apply_renames(tables)
      |> Renames.column_candidates(current)
      |> Enum.filter(fn {:column, table, from, to} ->
        Mix.shell().yes?("Was #{table}.#{from} renamed to #{to}?")
      end)

    tables ++ columns
  end

  defp check([]), do: Mix.shell().info("Migrations are up to date.")

  defp check(_ops) do
    Mix.raise("The authmk schema changed. Run `mix authmk.gen.migration` and commit the result.")
  end

  defp baseline(auth, snapshot_path) do
    Snapshot.write(snapshot_path, Migration.current_snapshot(auth))
    Mix.shell().info("Recorded the current schema in #{snapshot_path}. No migration written.")
  end

  defp generate(auth, repo, snapshot, snapshot_path, renames, opts) do
    ops = Migration.changes(auth, snapshot, renames)
    :ok = Diff.check_addable!(ops)

    if Diff.destructive?(ops) and not Keyword.get(opts, :allow_destructive, false) do
      Mix.raise(
        "This migration drops or changes existing tables or columns. " <>
          "Review the schema change and rerun with --allow-destructive."
      )
    end

    name = opts[:name] || "authmk"

    migrations_path =
      opts[:migrations_path] || Path.join(Mix.Authmk.repo_priv(repo), "migrations")

    timestamp = next_version(migrations_path)
    module = "#{inspect(repo)}.Migrations.#{Macro.camelize(name)}#{timestamp}"
    source = Migration.render(auth, snapshot, module, renames)

    # Ecto names a migration by what follows the version, and refuses two
    # pending ones with the same name: a counter keeps each one unique.
    base = Macro.underscore(name)

    file =
      Path.join(migrations_path, "#{timestamp}_#{base}_#{next_number(migrations_path, base)}.exs")

    File.mkdir_p!(migrations_path)

    formatted =
      source
      |> Code.format_string!(locals_without_parens: @migration_locals)
      |> IO.iodata_to_binary()

    File.write!(file, formatted <> "\n")
    Snapshot.write(snapshot_path, Migration.current_snapshot(auth))

    Mix.shell().info(
      "Wrote #{file}\nUpdated #{snapshot_path}\nRun `mix ecto.migrate` to apply it."
    )
  end

  # One more than the highest `<version>_<base>_<n>.exs` in the folder, so
  # deleting an old migration can't bring a number back.
  defp next_number(migrations_path, base) do
    pattern = ~r/\A\d+_#{Regex.escape(base)}_(\d+)\.exs\z/

    migrations_path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case Regex.run(pattern, Path.basename(file), capture: :all_but_first) do
        [number] -> [String.to_integer(number)]
        nil -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  # The current time as YYYYMMDDHHMMSS, bumped past the newest existing
  # migration so two runs in the same second can't share a version.
  defp next_version(migrations_path) do
    now = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S") |> String.to_integer()

    latest =
      migrations_path
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.basename() |> Integer.parse()))
      |> Enum.flat_map(fn
        {version, _rest} -> [version]
        :error -> []
      end)
      |> Enum.max(fn -> 0 end)

    max(now, latest + 1)
  end
end
