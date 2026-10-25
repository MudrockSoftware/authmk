defmodule Authmk.Users do
  @moduledoc false
  # Helpers for user records.

  alias Authmk.Context
  alias Authmk.Schema.{Changeset, Definition}

  @doc """
  The request params a user may set themselves (fields with `input: true`),
  with string keys.
  """
  @spec input_attrs(Context.t()) :: map()
  def input_attrs(%Context{config: config, raw_params: raw_params}) do
    names =
      config.schema
      |> Definition.model!(:user)
      |> Changeset.castable_fields(:input)
      |> Enum.map(&Atom.to_string(&1.name))

    Map.take(raw_params, names)
  end
end
