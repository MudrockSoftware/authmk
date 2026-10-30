defmodule Authmk.Serializer do
  @moduledoc false

  # Turns records into JSON-ready maps. Only fields with `returned: true` are
  # included, so password hashes and tokens never reach a response.

  alias Authmk.Context
  alias Authmk.Schema.Definition

  @doc "Public map of a record of `model`, or `nil`."
  @spec record(Context.t(), atom(), struct() | nil) :: map() | nil
  def record(_ctx, _model, nil), do: nil

  def record(%Context{config: config}, model, record) do
    model = Definition.model!(config.schema, model)
    fields = for field <- model.fields, field.returned, do: field.name
    timestamps = if model.timestamps, do: [:inserted_at, :updated_at], else: []

    Map.take(record, [:id | fields] ++ timestamps)
  end

  @doc "Public map of a user."
  @spec user(Context.t(), struct() | nil) :: map() | nil
  def user(ctx, user), do: record(ctx, :user, user)

  @doc "Public map of a session."
  @spec session(Context.t(), struct() | nil) :: map() | nil
  def session(ctx, session), do: record(ctx, :session, session)
end
