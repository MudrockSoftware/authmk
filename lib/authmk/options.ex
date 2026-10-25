defmodule Authmk.Options do
  @moduledoc """
  Option schemas for `use Authmk`.

  Compile-time options shape the database schema, so they can only be set in
  `use Authmk`. Runtime options can also be set (or overridden) in
  application config, for example in `config/runtime.exs`:

      config :my_app, MyApp.Auth, base_url: System.fetch_env!("BASE_URL")

  ## Compile-time options

  #{NimbleOptions.docs(Authmk.Options.Schemas.compile())}

  ## Runtime options

  #{NimbleOptions.docs(Authmk.Options.Schemas.runtime())}
  """

  alias Authmk.Options.Schemas

  @compile_keys Keyword.keys(Schemas.compile().schema)

  @doc "Compile-time option keys."
  @spec compile_keys() :: [atom()]
  def compile_keys, do: @compile_keys

  @doc "Validates the compile-time part of `use Authmk` options."
  @spec validate_compile!(keyword()) :: keyword()
  def validate_compile!(opts) do
    opts
    |> Keyword.take(@compile_keys)
    |> NimbleOptions.validate!(Schemas.compile())
    |> Keyword.update!(:plugins, fn plugins -> Enum.map(plugins, &normalize_plugin/1) end)
  end

  @doc "Validates runtime options: the rest of `use Authmk` merged with app config."
  @spec validate_runtime!(keyword()) :: keyword() | map()
  def validate_runtime!(opts) do
    NimbleOptions.validate!(Keyword.drop(opts, @compile_keys), Schemas.runtime())
  end

  defp normalize_plugin({plugin, opts}) when is_atom(plugin) and is_list(opts), do: {plugin, opts}
  defp normalize_plugin(plugin) when is_atom(plugin), do: {plugin, []}
end
