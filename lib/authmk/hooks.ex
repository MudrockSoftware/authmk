defmodule Authmk.Hooks do
  @moduledoc false
  # Runs endpoint and database hooks: every plugin in config order, then the
  # auth module itself.

  alias Authmk.{Context, Error}

  @spec before_endpoint(Context.t()) :: {:cont, Context.t()} | {:halt, Error.t()}
  def before_endpoint(%Context{} = ctx) do
    name = ctx.endpoint.name

    ctx
    |> hook_modules(:before_endpoint, 2)
    |> Enum.reduce_while({:cont, ctx}, fn module, {:cont, ctx} ->
      case module.before_endpoint(name, ctx) do
        {:cont, %Context{} = ctx} -> {:cont, {:cont, ctx}}
        {:halt, %Error{} = error} -> {:halt, {:halt, error}}
      end
    end)
  end

  @spec after_endpoint(Context.t(), term()) :: term()
  def after_endpoint(%Context{} = ctx, result) do
    name = ctx.endpoint.name

    ctx
    |> hook_modules(:after_endpoint, 3)
    |> Enum.reduce(result, fn module, result -> module.after_endpoint(name, ctx, result) end)
  end

  @doc "Runs `:before_*` database hooks. Each may change `data` or stop the write."
  @spec before_write(atom(), atom(), term(), Context.t()) :: {:ok, term()} | {:error, Error.t()}
  def before_write(event, model, data, ctx) do
    ctx
    |> hook_modules(:database_hook, 4)
    |> Enum.reduce_while({:ok, data}, fn module, {:ok, data} ->
      case module.database_hook(event, model, data, ctx) do
        {:ok, data} -> {:cont, {:ok, data}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Runs `:after_*` database hooks. Return values are ignored."
  @spec after_write(atom(), atom(), term(), Context.t()) :: :ok
  def after_write(event, model, record, ctx) do
    for module <- hook_modules(ctx, :database_hook, 4) do
      module.database_hook(event, model, record, ctx)
    end

    :ok
  end

  defp hook_modules(%Context{config: config}, function, arity) do
    plugins = Enum.map(config.plugins, &elem(&1, 0))
    Enum.filter(plugins ++ [config.auth], &function_exported?(&1, function, arity))
  end
end
