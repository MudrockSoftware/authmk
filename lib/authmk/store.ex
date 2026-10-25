defmodule Authmk.Store do
  @moduledoc """
  Database access for authmk models, through the app's repo.

  Writes run database hooks and emit `[:authmk, :store, :start | :stop |
  :exception]` telemetry events with `%{auth: module, model: atom, operation: atom}`.
  """

  import Ecto.Query

  alias Authmk.{Context, Error, Hooks}
  alias Authmk.Schema.{Changeset, Definition}

  @doc "Fetches one record by field values, or `nil`."
  @spec get_by(Context.t(), atom(), keyword()) :: struct() | nil
  def get_by(ctx, model, clauses) do
    span(ctx, model, :get_by, fn -> repo(ctx).get_by(module(ctx, model), clauses) end)
  end

  @doc """
  Lists records matching `clauses`, newest first. `:limit` defaults to the
  `find_many_limit` config.
  """
  @spec all(Context.t(), atom(), keyword() | Ecto.Query.dynamic_expr(), keyword()) :: [struct()]
  def all(ctx, model, clauses, opts \\ []) do
    limit = Keyword.get(opts, :limit, ctx.config.find_many_limit)

    query =
      from(record in module(ctx, model),
        where: ^clauses,
        order_by: [desc: record.inserted_at],
        limit: ^limit
      )

    span(ctx, model, :all, fn -> repo(ctx).all(query) end)
  end

  @doc "Inserts a record. `mode` is `:input` for request params, `:internal` otherwise."
  @spec insert(Context.t(), atom(), map(), :input | :internal) ::
          {:ok, struct()} | {:error, Error.t()}
  def insert(ctx, model, attrs, mode \\ :internal) do
    with {:ok, attrs} <- Hooks.before_write(:before_create, model, attrs, ctx),
         changeset = changeset(ctx, model, struct(module(ctx, model)), attrs, mode),
         {:ok, record} <- write(ctx, model, :insert, changeset) do
      Hooks.after_write(:after_create, model, record, ctx)
      {:ok, record}
    end
  end

  @doc "Updates a record."
  @spec update(Context.t(), atom(), struct(), map(), :input | :internal) ::
          {:ok, struct()} | {:error, Error.t()}
  def update(ctx, model, record, attrs, mode \\ :internal) do
    with {:ok, attrs} <- Hooks.before_write(:before_update, model, attrs, ctx),
         changeset = changeset(ctx, model, record, attrs, mode),
         {:ok, record} <- write(ctx, model, :update, changeset) do
      Hooks.after_write(:after_update, model, record, ctx)
      {:ok, record}
    end
  end

  @doc "Deletes a record."
  @spec delete(Context.t(), atom(), struct()) :: {:ok, struct()} | {:error, Error.t()}
  def delete(ctx, model, record) do
    with {:ok, record} <- Hooks.before_write(:before_delete, model, record, ctx),
         {:ok, record} <- write(ctx, model, :delete, record) do
      Hooks.after_write(:after_delete, model, record, ctx)
      {:ok, record}
    end
  end

  @doc "Deletes every record matching `clauses`, without hooks. Returns the count."
  @spec delete_all(Context.t(), atom(), Ecto.Query.dynamic_expr() | keyword()) ::
          non_neg_integer()
  def delete_all(ctx, model, clauses) do
    query = from(record in module(ctx, model), where: ^clauses)
    {count, _} = span(ctx, model, :delete_all, fn -> repo(ctx).delete_all(query) end)
    count
  end

  @doc "Runs `fun` in a transaction. `fun` returns `{:ok, value}` or `{:error, reason}`."
  @spec transaction(Context.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transaction(ctx, fun), do: repo(ctx).transact(fun)

  @doc "The Ecto schema module of a model."
  @spec module(Context.t(), atom()) :: module()
  def module(ctx, model), do: Definition.model!(ctx.config.schema, model).module

  defp changeset(ctx, model, struct, attrs, mode) do
    ctx.config.schema |> Definition.model!(model) |> Changeset.build(struct, attrs, mode)
  end

  defp write(ctx, model, operation, changeset_or_record) do
    result =
      span(ctx, model, operation, fn ->
        apply(repo(ctx), operation, [changeset_or_record])
      end)

    case result do
      {:ok, record} -> {:ok, record}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, Error.from_changeset(changeset)}
    end
  end

  defp repo(ctx), do: ctx.config.repo

  defp span(ctx, model, operation, fun) do
    metadata = %{auth: ctx.config.auth, model: model, operation: operation}
    :telemetry.span([:authmk, :store], metadata, fn -> {fun.(), metadata} end)
  end
end
