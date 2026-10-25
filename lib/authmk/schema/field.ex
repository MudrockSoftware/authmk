defmodule Authmk.Schema.Field do
  @types [:string, :text, :integer, :boolean, :datetime, :map]

  @spec_schema NimbleOptions.new!(
                 type: [
                   type: {:in, @types},
                   doc: "Value type. Every type works on SQLite, PostgreSQL and MySQL."
                 ],
                 references: [type: :atom, doc: "Key of the model this field points to."],
                 on_delete: [
                   type: {:in, [:nothing, :delete_all, :nilify_all]},
                   default: :nothing,
                   doc: "What happens to this row when the referenced row is deleted."
                 ],
                 required: [type: :boolean, default: false, doc: "Column is `NOT NULL`."],
                 default: [type: :any, doc: "Static default value."],
                 unique: [type: :boolean, default: false, doc: "Unique index on this column."],
                 index: [type: :boolean, default: false, doc: "Index on this column."],
                 input: [
                   type: :boolean,
                   default: true,
                   doc: "Whether request params may set this field."
                 ],
                 returned: [
                   type: :boolean,
                   default: true,
                   doc: "Whether API responses include this field."
                 ],
                 redact: [type: :boolean, default: false, doc: "Hide the value when inspected."],
                 source: [type: :atom, doc: "Column name, when it differs from the field name."],
                 validate: [
                   type: :keyword_list,
                   default: [],
                   doc: "Changeset validations: `length`, `format`, `number`, `inclusion`."
                 ]
               )

  @moduledoc """
  One field of a model in the resolved schema.

  Core, plugins and user config declare fields as keyword lists:

      email: [type: :string, required: true, unique: true, input: false]
      user_id: [references: :user, on_delete: :delete_all, required: true]

  ## Options

  #{NimbleOptions.docs(@spec_schema)}
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    :type,
    :references,
    :source,
    :default,
    on_delete: :nothing,
    required: false,
    unique: false,
    index: false,
    input: true,
    returned: true,
    redact: false,
    validate: []
  ]

  @type t :: %__MODULE__{}

  @doc "Builds a field from its keyword spec. Raises `ArgumentError` on invalid specs."
  @spec new(atom(), keyword()) :: t()
  def new(name, spec) do
    spec = validate!(name, spec)

    cond do
      spec[:type] && spec[:references] ->
        raise ArgumentError, "field #{inspect(name)} sets both :type and :references"

      is_nil(spec[:type]) and is_nil(spec[:references]) ->
        raise ArgumentError, "field #{inspect(name)} needs a :type or :references"

      spec[:references] && not String.ends_with?(Atom.to_string(name), "_id") ->
        raise ArgumentError, "reference field #{inspect(name)} must end in _id"

      true ->
        struct!(__MODULE__, [name: name] ++ spec)
    end
  end

  @doc "Column name in the database."
  @spec column(t()) :: atom()
  def column(%__MODULE__{source: nil, name: name}), do: name
  def column(%__MODULE__{source: source}), do: source

  @doc "Ecto type for a field. References use the schema's primary key type."
  @spec ecto_type(t(), :binary_id | :id) :: atom()
  def ecto_type(%__MODULE__{references: ref}, primary_key) when not is_nil(ref), do: primary_key
  def ecto_type(%__MODULE__{type: :text}, _primary_key), do: :string
  def ecto_type(%__MODULE__{type: :datetime}, _primary_key), do: :utc_datetime_usec
  def ecto_type(%__MODULE__{type: type}, _primary_key), do: type

  @doc "Association name for a reference field: `:user_id` becomes `:user`."
  @spec association(t()) :: atom()
  def association(%__MODULE__{name: name}) do
    name |> Atom.to_string() |> String.replace_suffix("_id", "") |> String.to_atom()
  end

  defp validate!(name, spec) do
    case NimbleOptions.validate(spec, @spec_schema) do
      {:ok, spec} -> spec
      {:error, error} -> raise ArgumentError, "invalid field #{inspect(name)}: #{error.message}"
    end
  end
end
