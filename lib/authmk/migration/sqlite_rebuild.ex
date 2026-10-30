defmodule Authmk.Migration.SQLiteRebuild do
  @moduledoc false

  # SQLite can't change a column in place, so a table with a changed column
  # is rebuilt: every change to that table becomes one `{:rebuild_table, name,
  # old, new}` operation, which `Authmk.Migration.Render` writes as SQLite's
  # documented procedure (https://www.sqlite.org/lang_altertable.html):
  #
  #   1. foreign keys off, on one connection, then a transaction;
  #   2. a new table with the new definition, and the rows copied into it
  #      (the columns both definitions have);
  #   3. the old table dropped (with foreign keys off, no `ON DELETE` action
  #      runs on the tables pointing at it) and the new one renamed to its name;
  #   4. its indexes created again, and `PRAGMA foreign_key_check` must pass,
  #      or everything rolls back;
  #   5. foreign keys on again.

  alias Authmk.Migration.Diff

  @doc "`ops` with each table that has a modified column rebuilt from `from` to `to`."
  @spec apply([Diff.op()], map(), map()) :: [tuple()]
  def apply(ops, from, to) do
    rebuilt = for {:modify_column, table, _column, _new, _old} <- ops, uniq: true, do: table

    {kept, _seen} = Enum.flat_map_reduce(ops, MapSet.new(), &fold(&1, &2, rebuilt, from, to))
    kept
  end

  # The table's first change becomes its rebuild; the rest go into it.
  defp fold(op, seen, rebuilt, from, to) do
    table = op_table(op)

    cond do
      table not in rebuilt -> {[op], seen}
      MapSet.member?(seen, table) -> {[], seen}
      true -> {[rebuild(table, from, to)], MapSet.put(seen, table)}
    end
  end

  defp rebuild(table, from, to),
    do: {:rebuild_table, table, from["tables"][table], to["tables"][table]}

  # Column and index changes fold into the rebuild. Renames stay: they run
  # first, and the rebuild copies from the renamed columns.
  @folded [:add_column, :remove_column, :modify_column, :create_index, :drop_index]

  defp op_table(op) when elem(op, 0) in @folded, do: elem(op, 1)
  defp op_table(_op), do: nil

  @doc "Columns to copy: those in both definitions, with the ID and timestamps."
  @spec copied_columns(map(), map()) :: [String.t()]
  def copied_columns(old, new) do
    common = old["columns"] |> Map.keys() |> Enum.filter(&Map.has_key?(new["columns"], &1))

    timestamps =
      if old["timestamps"] and new["timestamps"], do: ["inserted_at", "updated_at"], else: []

    ["id" | Enum.sort(common)] ++ timestamps
  end
end
