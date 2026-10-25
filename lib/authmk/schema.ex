defmodule Authmk.Schema do
  @moduledoc """
  Adds authmk's fields to an Ecto schema module that your app owns.

  Point the model at your module in config:

      use Authmk, schema: [user: [module: MyApp.Accounts.User, table: "users"]], ...

  Then call `authmk_fields/0` inside the schema block:

      defmodule MyApp.Accounts.User do
        use Ecto.Schema
        use Authmk.Schema, auth: MyApp.Auth, model: :user

        schema "users" do
          authmk_fields()
          has_many :posts, MyApp.Blog.Post
          timestamps()
        end
      end

  `use Authmk.Schema` sets `@primary_key`, `@foreign_key_type` and
  `@timestamps_opts` to match the auth module. Fields always follow the
  current config, so enabling a plugin updates the schema automatically.
  """

  alias Authmk.Schema.{Definition, EctoAst}

  defmacro __using__(opts) do
    auth = Macro.expand(Keyword.fetch!(opts, :auth), __CALLER__)
    model = Keyword.fetch!(opts, :model)

    # The whole module body is expanded before it runs, so `authmk_fields/0`
    # can only see what is recorded now, during expansion.
    Module.put_attribute(__CALLER__.module, :authmk_auth, auth)
    Module.put_attribute(__CALLER__.module, :authmk_model, model)

    quote do
      import Authmk.Schema, only: [authmk_fields: 0]

      @primary_key EctoAst.primary_key_attribute(unquote(auth).__authmk__(:schema))
      @foreign_key_type unquote(auth).__authmk__(:schema).primary_key
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end

  @doc false
  # Called by `use Authmk`: defines the Ecto schemas of library-owned models.
  @spec define_library_modules(Definition.t(), Macro.Env.t()) :: :ok
  def define_library_modules(definition, env) do
    definition
    |> Definition.sorted_models()
    |> Enum.filter(&(&1.owner == :library))
    |> Enum.each(&EctoAst.define_module(&1, definition, env))
  end

  @doc "Expands to every field authmk defines for this model."
  defmacro authmk_fields do
    auth = Module.get_attribute(__CALLER__.module, :authmk_auth)
    key = Module.get_attribute(__CALLER__.module, :authmk_model)
    definition = auth.__authmk__(:schema)
    model = Definition.model!(definition, key)

    if model.module != __CALLER__.module do
      raise ArgumentError,
            "#{inspect(auth)} expects the #{key} schema in #{inspect(model.module)}, " <>
              "not #{inspect(__CALLER__.module)}"
    end

    quote do
      (unquote_splicing(EctoAst.field_asts(model, definition)))
    end
  end
end
