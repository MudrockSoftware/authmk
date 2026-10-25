defmodule Authmk.Schema.Model do
  @moduledoc """
  One model (table) in the resolved schema.

  `owner` is `:library` when authmk generates the Ecto schema module, and
  `:user` when the app owns the module and calls `authmk_fields()` in it.
  """

  alias Authmk.Schema.Field

  @enforce_keys [:key, :table, :module, :owner]
  defstruct [:key, :table, :module, :owner, fields: [], indexes: [], timestamps: true]

  @type index :: %{name: String.t(), columns: [atom()], unique: boolean()}
  @type t :: %__MODULE__{
          key: atom(),
          table: String.t(),
          module: module(),
          owner: :library | :user,
          fields: [Field.t()],
          indexes: [index()],
          timestamps: boolean()
        }

  @doc "Returns the field named `name`, or `nil`."
  @spec field(t(), atom()) :: Field.t() | nil
  def field(%__MODULE__{fields: fields}, name), do: Enum.find(fields, &(&1.name == name))

  @doc """
  All indexes of the model: single-column ones declared on fields (`unique:`
  or `index:`) plus the model's own (multi-column) indexes.
  """
  @spec all_indexes(t()) :: [index()]
  def all_indexes(%__MODULE__{} = model) do
    field_indexes =
      for field <- model.fields, field.unique or field.index do
        index(model.table, [Field.column(field)], field.unique)
      end

    field_indexes ++ model.indexes
  end

  @doc "Builds an index with Ecto's default name, `<table>_<columns>_index`."
  @spec index(String.t(), [atom()], boolean()) :: index()
  def index(table, columns, unique) do
    %{name: "#{table}_#{Enum.join(columns, "_")}_index", columns: columns, unique: unique}
  end
end
