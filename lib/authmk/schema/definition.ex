defmodule Authmk.Schema.Definition do
  @moduledoc """
  The resolved schema of an auth module: core models, plus everything plugins
  and user config added. Ecto schemas, changesets and migrations all derive
  from it.
  """

  alias Authmk.Schema.Model

  @enforce_keys [:primary_key, :models]
  defstruct [:primary_key, :models]

  @type t :: %__MODULE__{primary_key: :binary_id | :id, models: %{atom() => Model.t()}}

  @doc "Returns the model for `key`. Raises if it doesn't exist."
  @spec model!(t(), atom()) :: Model.t()
  def model!(%__MODULE__{models: models}, key) do
    case Map.fetch(models, key) do
      {:ok, model} -> model
      :error -> raise ArgumentError, "unknown model #{inspect(key)}"
    end
  end

  @doc """
  Models ordered so that every model comes after the models it references.
  Tables can be created in this order.
  """
  @spec sorted_models(t()) :: [Model.t()]
  def sorted_models(%__MODULE__{models: models}) do
    models
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce([], &visit(&1, models, &2, []))
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(models, &1))
  end

  defp visit(key, models, sorted, path) do
    cond do
      key in sorted ->
        sorted

      key in path ->
        raise ArgumentError, "models reference each other in a cycle: #{inspect([key | path])}"

      true ->
        model = Map.fetch!(models, key)
        dependencies = for field <- model.fields, field.references, do: field.references

        sorted =
          dependencies
          |> Enum.reject(&(&1 == key))
          |> Enum.reduce(sorted, &visit(&1, models, &2, [key | path]))

        [key | sorted]
    end
  end
end
