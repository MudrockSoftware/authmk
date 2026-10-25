defmodule Authmk.Test.GreetingPlugin do
  @moduledoc false
  # A plugin that adds a table, a user field, an endpoint and hooks.
  use Authmk.Plugin

  alias Authmk.{Context, Endpoint, Error, Store}

  @impl true
  def init(opts), do: Keyword.put_new(opts, :greeting, "Hello")

  @impl true
  def schema(_opts) do
    %{
      user: [fields: [nickname: [type: :string]]],
      greeting_log: [
        plural: "greeting_logs",
        fields: [
          user_id: [references: :user, on_delete: :delete_all, required: true],
          message: [type: :string, required: true]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    [
      Endpoint.new(
        name: :greet,
        method: :post,
        path: "/greet",
        handler: {__MODULE__, :greet},
        session: :required,
        params: [punctuation: [type: :string, default: "!"]]
      )
    ]
  end

  @impl true
  def before_endpoint(:sign_up_email, ctx) do
    if String.ends_with?(ctx.raw_params["email"], "@blocked.example"),
      do: {:halt, Error.new(:forbidden)},
      else: {:cont, ctx}
  end

  def before_endpoint(_endpoint, ctx), do: {:cont, ctx}

  @impl true
  def database_hook(:before_create, :user, attrs, _ctx) do
    {:ok, Map.put_new(attrs, "nickname", "friend")}
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  def greet(ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    message = "#{opts[:greeting]}, #{ctx.user.nickname}#{ctx.params.punctuation}"
    {:ok, _log} = Store.insert(ctx, :greeting_log, %{user_id: ctx.user.id, message: message})
    {:ok, %{message: message}, ctx}
  end
end
