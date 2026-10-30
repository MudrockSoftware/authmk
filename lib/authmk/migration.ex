defmodule Authmk.Migration do
  @moduledoc """
  Generates migrations for an auth module's schema.

  The generator compares the current schema with the last snapshot (by
  default `priv/repo/authmk/<auth>.json`), renders an Ecto migration for the
  difference and writes the new snapshot. Commit both files.
  """

  alias Authmk.Migration.{Diff, Renames, Render, Snapshot, SQLiteRebuild}

  @doc "The adapter of a repo: `:sqlite`, `:postgres` or `:mysql`."
  @spec adapter(module()) :: :sqlite | :postgres | :mysql
  def adapter(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 -> :sqlite
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.MyXQL -> :mysql
      other -> raise ArgumentError, "authmk doesn't support the #{inspect(other)} adapter"
    end
  end

  @doc "Snapshot of the auth module's current schema."
  @spec current_snapshot(module()) :: Snapshot.t()
  def current_snapshot(auth), do: Snapshot.from_definition(auth.__authmk__(:schema))

  @doc """
  Source of a migration from `snapshot` to the current schema. Confirmed
  `renames` become renames instead of drops and adds.
  """
  @spec render(module(), Snapshot.t(), String.t(), [Renames.rename()]) :: String.t()
  def render(auth, snapshot, module_name, renames \\ []) do
    current = current_snapshot(auth)
    renamed = Renames.apply_renames(snapshot, renames)
    repo = auth.__authmk__(:compile_options)[:repo]

    # Renames run first going up, and are undone last going down.
    up = Renames.ops(renames) ++ Diff.diff(renamed, current)
    down = Diff.diff(current, renamed) ++ Renames.ops(Renames.reverse(renames))

    case adapter(repo) do
      :sqlite ->
        Render.migration(
          module_name,
          SQLiteRebuild.apply(up, renamed, current),
          SQLiteRebuild.apply(down, current, renamed),
          :sqlite
        )

      adapter ->
        Render.migration(module_name, up, down, adapter)
    end
  end

  @doc """
  `snapshot`, with `tables` recorded as they are in the current schema: for
  adopting tables the app already has (like `users`), which it brings to
  authmk's columns itself. Raises for tables the schema doesn't have.
  """
  @spec adopt(Snapshot.t(), module(), [String.t()]) :: Snapshot.t()
  def adopt(snapshot, auth, tables) do
    current = current_snapshot(auth)

    Enum.reduce(tables, snapshot, fn table, snapshot ->
      case current["tables"][table] do
        nil -> raise ArgumentError, "the authmk schema has no table #{table}"
        definition -> put_in(snapshot, ["tables", table], definition)
      end
    end)
  end

  @doc "Operations from `snapshot` to the current schema, with confirmed `renames` applied."
  @spec changes(module(), Snapshot.t(), [Renames.rename()]) :: [tuple()]
  def changes(auth, snapshot, renames \\ []) do
    Renames.ops(renames) ++
      Diff.diff(Renames.apply_renames(snapshot, renames), current_snapshot(auth))
  end
end
