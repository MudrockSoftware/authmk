defmodule Authmk.Migration.Renames do
  @moduledoc """
  Detects likely renames between two snapshots, so a renamed table or column
  can be renamed in place instead of dropped and re-created (losing data).

  A table that disappears while another with the same columns appears is a
  candidate (the tables their foreign keys point at may be renamed too, so
  those names aren't compared), and so is a column that disappears while another with the same
  definition appears in the same table. Nothing is renamed without
  confirmation; `mix authmk.gen.migration` asks about tables first, then
  about columns, given the table renames you confirmed.

  Confirmed renames are applied to the old snapshot before diffing, so
  everything else (indexes, foreign keys pointing at a renamed table) is
  compared against the renamed names.
  """

  alias Authmk.Migration.{Pairs, Snapshot}

  @type rename :: {:table, String.t(), String.t()} | {:column, String.t(), String.t(), String.t()}

  @doc "Possible table renames from `old` to `new`."
  @spec table_candidates(Snapshot.t(), Snapshot.t()) :: [rename()]
  def table_candidates(old, new), do: table_pairs(old["tables"], new["tables"])

  @doc """
  Possible column renames from `old` to `new`. Pass `old` with the confirmed
  table renames already applied.
  """
  @spec column_candidates(Snapshot.t(), Snapshot.t()) :: [rename()]
  def column_candidates(old, new) do
    for {name, new_table} <- Enum.sort(new["tables"]),
        old_table = old["tables"][name],
        old_table != nil,
        rename <- column_pairs(name, old_table["columns"], new_table["columns"]),
        do: rename
  end

  @doc "`old` with the confirmed renames applied."
  @spec apply_renames(Snapshot.t(), [rename()]) :: Snapshot.t()
  def apply_renames(snapshot, renames), do: Enum.reduce(renames, snapshot, &apply_rename/2)

  @doc "Operations for the renames, in order."
  @spec ops([rename()]) :: [tuple()]
  def ops(renames) do
    for rename <- renames do
      case rename do
        {:table, from, to} -> {:rename_table, from, to}
        {:column, table, from, to} -> {:rename_column, table, from, to}
      end
    end
  end

  @doc "The renames that undo `renames`, in reverse order."
  @spec reverse([rename()]) :: [rename()]
  def reverse(renames) do
    renames
    |> Enum.reverse()
    |> Enum.map(fn
      {:table, from, to} -> {:table, to, from}
      {:column, table, from, to} -> {:column, table, to, from}
    end)
  end

  defp table_pairs(old_tables, new_tables) do
    dropped =
      for {name, table} <- Enum.sort(old_tables),
          not Map.has_key?(new_tables, name),
          do: {name, table}

    created =
      for {name, table} <- Enum.sort(new_tables),
          not Map.has_key?(old_tables, name),
          do: {name, table}

    for {old_name, new_name, _table} <- Pairs.match(dropped, created, &same_table?/2),
        do: {:table, old_name, new_name}
  end

  defp same_table?(old_table, new_table) do
    new_table["primary_key"] == old_table["primary_key"] and
      without_reference_tables(new_table) == without_reference_tables(old_table)
  end

  defp without_reference_tables(table) do
    Map.new(table["columns"], fn
      {column, %{"references" => %{} = ref} = spec} ->
        {column, %{spec | "references" => Map.delete(ref, "table")}}

      {column, spec} ->
        {column, spec}
    end)
  end

  defp put_in_reference(%{"references" => %{"table" => table} = ref} = spec, table, replacement),
    do: %{spec | "references" => %{ref | "table" => replacement}}

  defp put_in_reference(spec, _table, _replacement), do: spec

  defp column_pairs(table, old_columns, new_columns) do
    removed =
      for {column, spec} <- Enum.sort(old_columns),
          not Map.has_key?(new_columns, column),
          do: {column, spec}

    added =
      for {column, spec} <- Enum.sort(new_columns),
          not Map.has_key?(old_columns, column),
          do: {column, spec}

    for {old_column, new_column, _spec} <- Pairs.match(removed, added, &(&1 == &2)),
        do: {:column, table, old_column, new_column}
  end

  defp apply_rename({:table, from, to}, snapshot) do
    tables = snapshot["tables"]
    {table, tables} = Map.pop!(tables, from)

    tables =
      tables
      |> Map.put(to, table)
      |> Map.new(fn {name, table} ->
        {name, update_columns(table, &put_in_reference(&1, from, to))}
      end)

    %{snapshot | "tables" => tables}
  end

  defp apply_rename({:column, table_name, from, to}, snapshot) do
    update_in(snapshot, ["tables", table_name], fn table ->
      {spec, columns} = Map.pop!(table["columns"], from)

      indexes =
        Map.new(table["indexes"], fn {name, index} ->
          {name, %{index | "columns" => Enum.map(index["columns"], &rename_column(&1, from, to))}}
        end)

      %{table | "columns" => Map.put(columns, to, spec), "indexes" => indexes}
    end)
  end

  defp rename_column(from, from, to), do: to
  defp rename_column(column, _from, _to), do: column

  defp update_columns(table, fun) do
    %{
      table
      | "columns" => Map.new(table["columns"], fn {column, spec} -> {column, fun.(spec)} end)
    }
  end
end
