defmodule Authmk.Schema.Changeset do
  @moduledoc false

  # Builds Ecto changesets from a model's field specs.
  #
  # In `:input` mode only fields with `input: true` are cast, so request params
  # can never set fields like `email_verified`. `:internal` mode casts every
  # field and is used by authmk itself.

  import Ecto.Changeset

  alias Authmk.Schema.{Field, Model}

  # MySQL's VARCHAR(255) would reject or truncate longer values.
  @string_max_length 255

  @doc "Changeset for inserting or updating a record of `model`."
  @spec build(Model.t(), struct(), map(), :input | :internal) :: Ecto.Changeset.t()
  def build(%Model{} = model, struct, attrs, mode) do
    fields = castable_fields(model, mode)
    names = Enum.map(fields, & &1.name)
    required = for field <- fields, field.required, do: field.name

    struct
    |> cast(attrs, names)
    |> validate_required(required)
    |> validate_fields(fields)
    |> add_constraints(model)
  end

  @doc "Fields that `mode` may set."
  @spec castable_fields(Model.t(), :input | :internal) :: [Field.t()]
  def castable_fields(model, :internal), do: model.fields
  def castable_fields(model, :input), do: Enum.filter(model.fields, & &1.input)

  defp validate_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      changeset
      |> validate_string_length(field)
      |> apply_rules(field.name, field.validate)
    end)
  end

  defp validate_string_length(changeset, %Field{type: :string, references: nil, name: name}),
    do: validate_length(changeset, name, max: @string_max_length)

  defp validate_string_length(changeset, _field), do: changeset

  defp apply_rules(changeset, name, rules) do
    Enum.reduce(rules, changeset, fn
      {:length, opts}, cs -> validate_length(cs, name, opts)
      {:format, regex}, cs -> validate_format(cs, name, regex)
      {:number, opts}, cs -> validate_number(cs, name, opts)
      {:inclusion, values}, cs -> validate_inclusion(cs, name, values)
      {rule, _}, _cs -> raise ArgumentError, "unknown validation #{inspect(rule)} on #{name}"
    end)
  end

  defp add_constraints(changeset, model) do
    changeset =
      Enum.reduce(model.fields, changeset, fn
        %Field{references: nil}, cs -> cs
        field, cs -> foreign_key_constraint(cs, field.name)
      end)

    model
    |> Model.all_indexes()
    |> Enum.filter(& &1.unique)
    |> Enum.reduce(changeset, fn index, cs ->
      field = field_for_column(model, hd(index.columns))
      unique_constraint(cs, field, name: index.name)
    end)
  end

  defp field_for_column(model, column) do
    Enum.find_value(model.fields, column, &(Field.column(&1) == column && &1.name))
  end
end
