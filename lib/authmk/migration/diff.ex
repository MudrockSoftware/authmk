defmodule Authmk.Migration.Diff do
  @moduledoc false

  # Compares two snapshots and lists the operations that turn the old database
  # into the new one.
  #
  # Operations come in a safe order: drop changed indexes, create tables
  # (referenced tables first), add, modify and remove columns, create indexes,
  # and finally drop tables (referencing tables first).

  alias Authmk.Migration.{Pairs, Snapshot}

  @type op ::
          {:create_table, String.t(), map()}
          | {:drop_table, String.t(), map()}
          | {:add_column, String.t(), String.t(), map()}
          | {:modify_column, String.t(), String.t(), map(), map()}
          | {:remove_column, String.t(), String.t(), map()}
          | {:create_index, String.t(), String.t(), map()}
          | {:drop_index, String.t(), String.t(), map()}
          | {:rename_index, String.t(), String.t(), String.t(), map()}

  @doc "Operations from `old` to `new`. Raises on changes no migration can make safely."
  @spec diff(Snapshot.t(), Snapshot.t()) :: [op()]
  def diff(old, new) do
    old_tables = old["tables"]
    new_tables = new["tables"]
    common = for {name, _} <- new_tables, Map.has_key?(old_tables, name), do: name

    created = for name <- order(new_tables), not Map.has_key?(old_tables, name), do: name

    dropped =
      for name <- Enum.reverse(order(old_tables)), not Map.has_key?(new_tables, name), do: name

    Enum.each(common, &check_table_settings!(&1, old_tables[&1], new_tables[&1]))

    Enum.flat_map(common, &index_renames(&1, old_tables[&1], new_tables[&1])) ++
      Enum.flat_map(common, &index_ops(:drop_index, &1, old_tables[&1], new_tables[&1])) ++
      Enum.flat_map(created, &create_table_ops(&1, new_tables[&1])) ++
      Enum.flat_map(common, &column_ops(&1, old_tables[&1], new_tables[&1])) ++
      Enum.flat_map(common, &index_ops(:create_index, &1, new_tables[&1], old_tables[&1])) ++
      Enum.map(dropped, &{:drop_table, &1, old_tables[&1]})
  end

  @doc "Whether any operation can lose data."
  @spec destructive?([op()]) :: boolean()
  def destructive?(ops) do
    Enum.any?(ops, &(elem(&1, 0) in [:drop_table, :remove_column, :modify_column]))
  end

  defp create_table_ops(name, table) do
    indexes =
      for {index_name, index} <- Enum.sort(table["indexes"]),
          do: {:create_index, name, index_name, index}

    [{:create_table, name, table} | indexes]
  end

  # Indexes in `table` that `other` lacks, or has with different settings.
  # Indexes in `table` that `other` lacks, or has with different settings.
  # Indexes that were only renamed are left to `index_renames/3`.
  defp index_ops(op, name, table, other) do
    renamed = renamed_indexes(table, other)

    for {index_name, index} <- Enum.sort(table["indexes"]),
        other["indexes"][index_name] != index,
        index_name not in renamed do
      {op, name, index_name, index}
    end
  end

  # An index with the same definition under a new name (for example after a
  # table rename) is renamed in place: MySQL won't drop an index a foreign
  # key needs.
  defp index_renames(name, old, new) do
    for {old_name, new_name, index} <- index_rename_pairs(old, new) do
      {:rename_index, name, old_name, new_name, index}
    end
  end

  defp renamed_indexes(table, other) do
    pairs = index_rename_pairs(table, other) ++ index_rename_pairs(other, table)
    Enum.flat_map(pairs, fn {old_name, new_name, _index} -> [old_name, new_name] end)
  end

  defp index_rename_pairs(old, new) do
    gone =
      for {name, index} <- Enum.sort(old["indexes"]),
          not Map.has_key?(new["indexes"], name),
          do: {name, index}

    added =
      for {name, index} <- Enum.sort(new["indexes"]),
          not Map.has_key?(old["indexes"], name),
          do: {name, index}

    Pairs.match(gone, added, &(&1 == &2))
  end

  defp column_ops(name, old, new) do
    old_columns = old["columns"]
    new_columns = new["columns"]

    added =
      for {column, spec} <- Enum.sort(new_columns), not Map.has_key?(old_columns, column) do
        {:add_column, name, column, spec}
      end

    modified =
      for {column, spec} <- Enum.sort(new_columns), changed?(old_columns[column], spec) do
        {:modify_column, name, column, spec, old_columns[column]}
      end

    removed =
      for {column, spec} <- Enum.sort(old_columns), not Map.has_key?(new_columns, column) do
        {:remove_column, name, column, spec}
      end

    added ++ modified ++ removed
  end

  # A column missing from the old table is an add, not a change.
  defp changed?(nil, _spec), do: false
  defp changed?(old_spec, spec), do: old_spec != spec

  @doc """
  Raises for operations that can't run on a table with rows: adding a
  `NOT NULL` column without a default leaves existing rows without a value.
  """
  @spec check_addable!([op()]) :: :ok
  def check_addable!(ops) do
    for {:add_column, table, column, %{"null" => false, "default" => nil}} <- ops do
      raise ArgumentError,
            "can't add #{table}.#{column}: a new column on an existing table must be " <>
              "nullable or have a default. If it replaces a column, confirm the rename"
    end

    :ok
  end

  defp check_table_settings!(name, old, new) do
    for key <- ["primary_key", "timestamps"], old[key] != new[key] do
      raise ArgumentError, "can't change #{key} of existing table #{name}"
    end
  end

  # Table names ordered so referenced tables come first.
  defp order(tables) do
    tables
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce([], &visit(&1, tables, &2))
    |> Enum.reverse()
  end

  defp visit(name, tables, sorted) do
    if name in sorted or not Map.has_key?(tables, name) do
      sorted
    else
      dependencies =
        for {_column, %{"references" => %{"table" => target}}} <- tables[name]["columns"],
            target != name,
            do: target

      [name | Enum.reduce(Enum.sort(dependencies), sorted, &visit(&1, tables, &2))]
    end
  end
end
