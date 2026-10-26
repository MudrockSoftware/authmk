defmodule Authmk.Plugins.APIKey.KeyStore do
  @moduledoc false
  # Where API keys live, by the `storage` option:
  #
  #   * `:database` - the `api_key` table;
  #   * `:secondary_storage` - secondary storage only;
  #   * `:both` - the table for keeping and listing keys, secondary storage
  #     for checking them (and counting their uses), falling back to the
  #     table when a key isn't there.

  alias Authmk.Plugins.APIKey.{DatabaseStore, SecondaryStore}

  def insert(ctx, mode, attrs) do
    case mode do
      :database ->
        DatabaseStore.insert(ctx, attrs)

      :secondary_storage ->
        SecondaryStore.insert(ctx, attrs)

      :both ->
        with {:ok, key} <- DatabaseStore.insert(ctx, attrs), do: SecondaryStore.store(ctx, key)
    end
  end

  def get(ctx, :database, id), do: DatabaseStore.get(ctx, id)
  def get(ctx, :secondary_storage, id), do: SecondaryStore.get(ctx, id)

  def get(ctx, :both, id),
    do: SecondaryStore.get(ctx, id) || recache(ctx, DatabaseStore.get(ctx, id))

  def get_by_hash(ctx, :database, hash), do: DatabaseStore.get_by_hash(ctx, hash)
  def get_by_hash(ctx, :secondary_storage, hash), do: SecondaryStore.get_by_hash(ctx, hash)

  def get_by_hash(ctx, :both, hash),
    do:
      SecondaryStore.get_by_hash(ctx, hash) || recache(ctx, DatabaseStore.get_by_hash(ctx, hash))

  def list(ctx, :secondary_storage, owner, id), do: SecondaryStore.list(ctx, owner, id)
  def list(ctx, _database_or_both, owner, id), do: DatabaseStore.list(ctx, owner, id)

  def update(ctx, :database, key, attrs), do: DatabaseStore.update(ctx, key, attrs)
  def update(ctx, :secondary_storage, key, attrs), do: SecondaryStore.update(ctx, key, attrs)

  def update(ctx, :both, key, attrs) do
    with {:ok, updated} <- DatabaseStore.update(ctx, key, attrs) do
      _cached = SecondaryStore.update(ctx, key, attrs)
      {:ok, updated}
    end
  end

  def delete(ctx, :database, key), do: DatabaseStore.delete(ctx, key)
  def delete(ctx, :secondary_storage, key), do: SecondaryStore.delete(ctx, key)

  def delete(ctx, :both, key) do
    :ok = DatabaseStore.delete(ctx, key)
    SecondaryStore.delete(ctx, key)
  end

  def delete_expired(ctx, :secondary_storage, now), do: SecondaryStore.delete_expired(ctx, now)
  def delete_expired(ctx, _database_or_both, now), do: DatabaseStore.delete_expired(ctx, now)

  def use(ctx, :database, key, now), do: DatabaseStore.use(ctx, key, now)
  def use(ctx, _secondary_or_both, key, now), do: SecondaryStore.use(ctx, key, now)

  defp recache(_ctx, nil), do: nil

  defp recache(ctx, key) do
    {:ok, cached} = SecondaryStore.store(ctx, key)
    cached
  end
end
