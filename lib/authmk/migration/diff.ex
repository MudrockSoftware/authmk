defmodule Authmk.Migration.Diff do
  @moduledoc """
  Compares two snapshots and lists the operations that turn the old database
  into the new one.

  Operations come in a safe order: drop changed indexes, create tables
  (referenced tables first), add, modify and remove columns, create indexes,
  and finally drop tables (referencing tables first).
  """

  alias Authmk.Migration.Snapshot

  @type op ::
          {:create_table, String.t(), map()}
          | {:drop_table, String.t(), map()}
          | {:add_column, String.t(), String.t(), map()}
          | {:modify_column, String.t(), String.t(), map(), map()}
          | {:remove_column, String.t(), String.t(), map()}
          | {:create_index, String.t(), String.t(), map()}
          | {:drop_index, String.t(), String.t(), map()}

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
  defp index_ops(op, name, table, other) do
    for {index_name, index} <- Enum.sort(table["indexes"]),
        other["indexes"][index_name] != index do
      {op, name, index_name, index}
    end
  end

  defp column_ops(name, old, new) do
    old_columns = old["columns"]
    new_columns = new["columns"]

    added =
      for {column, spec} <- Enum.sort(new_columns), not Map.has_key?(old_columns, column) do
        check_addable!(name, column, spec)
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

  # Existing rows need a value for a new NOT NULL column.
  defp check_addable!(table, column, %{"null" => false, "default" => nil}) do
    raise ArgumentError,
          "can't add #{table}.#{column}: a new column on an existing table must be " <>
            "nullable or have a default"
  end

  defp check_addable!(_table, _column, _spec), do: :ok

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
