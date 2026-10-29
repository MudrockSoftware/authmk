defmodule Authmk.Plugins.JWT.KeyStore do
  @moduledoc """
  Where the JWT plugin keeps its signing keys. The default is
  `Authmk.Plugins.JWT.DatabaseKeyStore` (the `jwks` table). Implement this
  behaviour to keep them elsewhere, and pass the module as `key_store`.

  Keys are maps with `:id` (the `kid`), `:public_key` (a JWK as JSON),
  `:private_key` (JSON, or encrypted JSON), `:algorithm` and `:inserted_at`.
  """

  alias Authmk.Context

  @doc "Every key, newest first."
  @callback list(Context.t()) :: [map()]

  @doc "Stores a new key: `attrs` has everything but `:id` and `:inserted_at`."
  @callback insert(Context.t(), attrs :: map()) :: {:ok, map()} | {:error, term()}
end

defmodule Authmk.Plugins.JWT.DatabaseKeyStore do
  @moduledoc "Keys in the `jwks` table. See `Authmk.Plugins.JWT.KeyStore`."

  @behaviour Authmk.Plugins.JWT.KeyStore

  alias Authmk.Store

  @impl true
  def list(ctx), do: ctx |> Store.all(:jwks, [], limit: 100) |> Enum.map(&to_map/1)

  @impl true
  def insert(ctx, attrs) do
    with {:ok, record} <- Store.insert(ctx, :jwks, attrs), do: {:ok, to_map(record)}
  end

  defp to_map(record) do
    %{
      id: to_string(record.id),
      public_key: record.public_key,
      private_key: record.private_key,
      algorithm: record.algorithm,
      inserted_at: record.inserted_at
    }
  end
end
