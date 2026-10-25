defmodule Authmk.Migration do
  @moduledoc """
  Generates migrations for an auth module's schema.

  The generator compares the current schema with the last snapshot (by
  default `priv/repo/authmk/<auth>.json`), renders an Ecto migration for the
  difference and writes the new snapshot. Commit both files.
  """

  alias Authmk.Migration.{Diff, Render, Snapshot}

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

  @doc "Operations from `snapshot` to the auth module's current schema."
  @spec changes(module(), Snapshot.t()) :: [Diff.op()]
  def changes(auth, snapshot), do: Diff.diff(snapshot, current_snapshot(auth))

  @doc "Snapshot of the auth module's current schema."
  @spec current_snapshot(module()) :: Snapshot.t()
  def current_snapshot(auth), do: Snapshot.from_definition(auth.__authmk__(:schema))

  @doc "Source of a migration from `snapshot` to the current schema."
  @spec render(module(), Snapshot.t(), String.t()) :: String.t()
  def render(auth, snapshot, module_name) do
    current = current_snapshot(auth)
    repo = auth.__authmk__(:compile_options)[:repo]

    Render.migration(
      module_name,
      Diff.diff(snapshot, current),
      Diff.diff(current, snapshot),
      adapter(repo)
    )
  end
end
