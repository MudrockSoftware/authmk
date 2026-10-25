defmodule Authmk.Input do
  @moduledoc false
  # Request params that clients may set on a model.

  alias Authmk.Context
  alias Authmk.Schema.{Changeset, Definition}

  @doc """
  The request params a client may set on `model` (fields with
  `input: true`), with string keys.
  """
  @spec attrs(Context.t(), atom()) :: map()
  def attrs(%Context{config: config, raw_params: raw_params}, model) do
    names =
      config.schema
      |> Definition.model!(model)
      |> Changeset.castable_fields(:input)
      |> Enum.map(&Atom.to_string(&1.name))

    Map.take(raw_params, names)
  end
end
