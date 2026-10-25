defmodule Authmk.Params do
  @moduledoc false
  # Casts and validates endpoint params with a schemaless changeset.

  import Ecto.Changeset

  alias Authmk.Error

  @spec cast(keyword(), map()) :: {:ok, map()} | {:error, Error.t()}
  def cast(spec, raw) do
    types = Map.new(spec, fn {name, opts} -> {name, Keyword.fetch!(opts, :type)} end)
    defaults = Map.new(spec, fn {name, opts} -> {name, Keyword.get(opts, :default)} end)
    required = for {name, opts} <- spec, opts[:required], do: name

    {defaults, types}
    |> cast(raw, Map.keys(types))
    |> validate_required(required)
    |> apply_action(:validate)
    |> case do
      {:ok, params} -> {:ok, params}
      {:error, changeset} -> {:error, Error.from_changeset(changeset)}
    end
  end
end
