defmodule Authmk.Migration.Snapshot do
  @moduledoc """
  A JSON-friendly description of the tables a schema needs. The migration
  generator commits one next to the migrations and compares it with the
  current schema to find what changed.

      %{
        "version" => 1,
        "tables" => %{
          "users" => %{
            "primary_key" => "binary_id",
            "timestamps" => true,
            "columns" => %{"email" => %{"type" => "string", "null" => false, ...}},
            "indexes" => %{"users_email_index" => %{"columns" => ["email"], "unique" => true}}
          }
        }
      }
  """

  alias Authmk.Schema.{Definition, Field, Model}

  @version 1

  @type t :: map()

  @doc "A snapshot with no tables."
  @spec empty() :: t()
  def empty, do: %{"version" => @version, "tables" => %{}}

  @doc "The snapshot of a resolved schema."
  @spec from_definition(Definition.t()) :: t()
  def from_definition(%Definition{} = definition) do
    tables =
      Map.new(definition.models, fn {_key, model} ->
        {model.table, table(model, definition)}
      end)

    %{"version" => @version, "tables" => tables}
  end

  @doc "Reads a snapshot file, or returns `empty/0` when it doesn't exist."
  @spec read(Path.t()) :: t()
  def read(path) do
    case File.read(path) do
      {:ok, json} -> JSON.decode!(json)
      {:error, :enoent} -> empty()
    end
  end

  @doc "Writes a snapshot file with sorted keys, so diffs stay small."
  @spec write(Path.t(), t()) :: :ok
  def write(path, snapshot) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(snapshot) <> "\n")
  end

  defp table(model, definition) do
    %{
      "primary_key" => Atom.to_string(definition.primary_key),
      "timestamps" => model.timestamps,
      "columns" =>
        Map.new(model.fields, &{Atom.to_string(Field.column(&1)), column(&1, definition)}),
      "indexes" =>
        model
        |> Model.all_indexes()
        |> Map.new(fn index ->
          {index.name,
           %{"columns" => Enum.map(index.columns, &Atom.to_string/1), "unique" => index.unique}}
        end)
    }
  end

  defp column(%Field{references: nil} = field, _definition) do
    %{
      "type" => migration_type(field.type),
      "null" => not field.required,
      "default" => field.default,
      "references" => nil
    }
  end

  defp column(%Field{} = field, definition) do
    target = Definition.model!(definition, field.references)

    %{
      "type" => "references",
      "null" => not field.required,
      "default" => nil,
      "references" => %{
        "table" => target.table,
        "type" => Atom.to_string(definition.primary_key),
        "on_delete" => Atom.to_string(field.on_delete)
      }
    }
  end

  defp migration_type(:datetime), do: "utc_datetime_usec"
  defp migration_type(type), do: Atom.to_string(type)

  # Pretty-printed JSON with sorted keys.
  defp encode(value, indent \\ "")

  defp encode(map, _indent) when map_size(map) == 0, do: "{}"

  defp encode(map, indent) when is_map(map) do
    inner = indent <> "  "

    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} ->
        inner <> JSON.encode!(key) <> ": " <> encode(value, inner)
      end)

    "{\n" <> Enum.join(entries, ",\n") <> "\n" <> indent <> "}"
  end

  defp encode(list, _indent) when is_list(list), do: JSON.encode!(list)
  defp encode(value, _indent), do: JSON.encode!(value)
end
