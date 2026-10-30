defmodule Authmk.Dashboard.Data.Fields do
  @moduledoc false
  # The fields the app declares on users and organizations
  # (`additional_fields` in its schema config): shown by their types, and
  # editable where `input: true` allows it. Fields that aren't `returned`
  # stay hidden, as they are from the API.

  alias Authmk.Schema.Definition

  @models [:user, :organization]

  @doc "The app's own fields of `model`, as the dashboard describes them."
  def definitions(ctx, model), do: Enum.map(fields(ctx, model), &describe/1)

  @doc "The values of those fields on `record`, as JSON-ready values."
  def values(ctx, model, record) do
    Map.new(fields(ctx, model), fn field ->
      {Atom.to_string(field.name), encode(field.type, Map.get(record, field.name))}
    end)
  end

  defp fields(ctx, model) when model in @models do
    names = declared(ctx, model)

    for field <- Definition.model!(ctx.config.schema, model).fields,
        field.name in names,
        field.returned,
        do: field
  end

  @doc """
  The editable fields' new values from `params` (string keys), converted
  to their types: `{:ok, attrs}` or `{:error, message}`. Unknown and
  read-only fields are refused, not dropped: the admin should know.
  """
  def cast(ctx, model, params) when is_map(params) do
    editable =
      for field <- fields(ctx, model),
          field.input,
          into: %{},
          do: {Atom.to_string(field.name), field}

    Enum.reduce_while(params, {:ok, %{}}, fn {name, value}, {:ok, attrs} ->
      case Map.fetch(editable, name) do
        {:ok, field} -> convert(field, value, attrs)
        :error -> {:halt, {:error, "#{name} can't be changed here"}}
      end
    end)
  end

  def cast(_ctx, _model, _params), do: {:error, "fields must be an object"}

  defp convert(field, value, attrs) do
    case decode(field.type, value) do
      {:ok, decoded} -> {:cont, {:ok, Map.put(attrs, Atom.to_string(field.name), decoded)}}
      :error -> {:halt, {:error, "#{field.name} must be #{article(field.type)}"}}
    end
  end

  defp declared(%{config: config}, model) do
    schema = config.auth.__authmk__(:compile_options)[:schema] || []
    for {name, _spec} <- get_in(schema, [model, :additional_fields]) || [], do: name
  end

  defp describe(field) do
    %{
      name: Atom.to_string(field.name),
      type: Atom.to_string(field.type || :string),
      required: field.required,
      editable: field.input,
      options: options(field)
    }
  end

  # A field validated to a list of values is a choice between them.
  defp options(field) do
    case field.validate[:inclusion] do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      _free -> nil
    end
  end

  defp encode(_type, nil), do: nil
  defp encode(:datetime, %DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode(_type, value), do: value

  defp decode(_type, nil), do: {:ok, nil}

  defp decode(type, value) when type in [:string, :text, nil] and is_binary(value),
    do: {:ok, value}

  defp decode(:integer, value) when is_integer(value), do: {:ok, value}
  defp decode(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp decode(:map, value) when is_map(value), do: {:ok, value}

  defp decode(:datetime, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> :error
    end
  end

  defp decode(_type, _value), do: :error

  defp article(:integer), do: "a whole number"
  defp article(:boolean), do: "true or false"
  defp article(:map), do: "an object"
  defp article(:datetime), do: "a date and time"
  defp article(_text), do: "text"
end
