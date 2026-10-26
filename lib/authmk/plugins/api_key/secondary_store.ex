defmodule Authmk.Plugins.APIKey.SecondaryStore do
  @moduledoc false
  # API keys in secondary storage: each key as JSON, found by id, by its
  # hash, and by owner. Uses and rate limits are atomic counters
  # (`Authmk.Storage.increment/3`): uses per refill period, requests per
  # window. Keys that expire disappear on their own.

  alias Authmk.Storage

  @times [:expires_at, :last_refill_at, :last_request_at, :inserted_at, :updated_at]

  def insert(ctx, attrs) do
    now = DateTime.utc_now()
    store(ctx, Map.merge(attrs, %{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now}))
  end

  @doc "Stores a key that has an id already (a database copy, with `:both`)."
  def store(%{config: config}, key) do
    key = key |> Map.put(:allowance, key[:remaining]) |> Map.delete(:remaining)
    :ok = put(config, key)
    :ok = Storage.put(config, hash_key(key.key), key.id, ttl(key))
    :ok = add_to_owner(config, key)
    {:ok, with_remaining(config, key, DateTime.utc_now())}
  end

  def get(%{config: config}, id) do
    case Storage.get(config, record_key(id)) do
      nil -> nil
      json -> with_remaining(config, decode(json), DateTime.utc_now())
    end
  end

  def get_by_hash(%{config: config} = ctx, hash) do
    case Storage.get(config, hash_key(hash)) do
      nil -> nil
      id -> get(ctx, id)
    end
  end

  def list(%{config: config} = ctx, owner, owner_id) do
    config
    |> owner_ids(owner, owner_id)
    |> Enum.map(&get(ctx, &1))
    |> Enum.reject(&is_nil/1)
  end

  def update(%{config: config} = ctx, %{id: id}, attrs) do
    case get(ctx, id) do
      nil ->
        {:error, :not_found}

      key ->
        key =
          key
          |> Map.merge(Map.delete(attrs, :remaining))
          |> Map.put(:updated_at, DateTime.utc_now())
          |> new_allowance(config, attrs)

        :ok = put(config, key)
        {:ok, with_remaining(config, key, DateTime.utc_now())}
    end
  end

  def delete(%{config: config}, key) do
    :ok = Storage.delete(config, record_key(key.id))
    :ok = Storage.delete(config, hash_key(key.key))
    :ok = remove_from_owner(config, key)
  end

  # A new `remaining` starts the current period over with that many uses.
  defp new_allowance(key, config, %{remaining: remaining}) do
    {period, _allowance} = period(key, DateTime.utc_now())
    :ok = Storage.delete(config, uses_key(key, period))
    if period == 0, do: %{key | allowance: remaining}, else: %{key | refill_amount: remaining}
  end

  defp new_allowance(key, _config, _attrs), do: key

  # Expired keys already went with their storage TTL.
  def delete_expired(_ctx, _now), do: 0

  def use(%{config: config} = ctx, key, now) do
    with :ok <- take_use(config, key, now),
         :ok <- within_rate_limit(config, key, now) do
      update(ctx, key, %{last_request_at: now})
    end
  end

  # Uses are counted per refill period; each period allows `refill_amount`
  # (the first, `remaining` as created).
  defp take_use(_config, %{allowance: nil}, _now), do: :ok

  defp take_use(config, key, now) do
    {period, allowance} = period(key, now)
    used = Storage.increment(config, uses_key(key, period), period_ttl(key))
    if used <= allowance, do: :ok, else: {:error, :usage_exceeded}
  end

  defp within_rate_limit(_config, %{rate_limit_enabled: false}, _now), do: :ok

  defp within_rate_limit(config, key, now) do
    window = key.rate_limit_time_window
    index = div(DateTime.to_unix(now), window)
    count = Storage.increment(config, "api-key:requests:#{key.id}:#{index}", window)
    if count <= key.rate_limit_max, do: :ok, else: {:error, :rate_limited}
  end

  defp period(%{refill_interval: interval, refill_amount: amount} = key, now)
       when is_integer(interval) and is_integer(amount) do
    case div(DateTime.diff(now, key.inserted_at), interval) do
      0 -> {0, key.allowance}
      period -> {period, amount}
    end
  end

  defp period(key, _now), do: {0, key.allowance}

  # Counters for keys that never refill last as long as the key (or ten
  # years, for keys that don't expire).
  defp period_ttl(%{refill_interval: interval}) when is_integer(interval), do: interval * 2
  defp period_ttl(key), do: ttl(key) || 10 * 365 * 86_400

  # `remaining` as clients see it: the period's allowance minus its uses.
  defp with_remaining(config, key, now) do
    case key do
      %{allowance: nil} ->
        Map.put(key, :remaining, nil)

      key ->
        {period, allowance} = period(key, now)
        used = String.to_integer(Storage.get(config, uses_key(key, period)) || "0")
        Map.put(key, :remaining, max(allowance - used, 0))
    end
  end

  defp put(config, key) do
    stored = key |> Map.delete(:remaining) |> encode()
    Storage.put(config, record_key(key.id), stored, ttl(key))
  end

  defp ttl(%{expires_at: nil}), do: nil
  defp ttl(%{expires_at: expires_at}), do: max(DateTime.diff(expires_at, DateTime.utc_now()), 1)

  defp add_to_owner(config, key) do
    {owner, owner_id} = owner(key)
    ids = owner_ids(config, owner, owner_id)
    Storage.put(config, owner_key(owner, owner_id), JSON.encode!(Enum.uniq([key.id | ids])), nil)
  end

  defp remove_from_owner(config, key) do
    {owner, owner_id} = owner(key)
    ids = owner_ids(config, owner, owner_id) -- [key.id]
    Storage.put(config, owner_key(owner, owner_id), JSON.encode!(ids), nil)
  end

  defp owner(%{service_account_id: id}) when not is_nil(id), do: {:service_account_id, id}
  defp owner(%{organization_id: id}) when not is_nil(id), do: {:organization_id, id}
  defp owner(%{user_id: id}), do: {:user_id, id}

  defp owner_ids(config, owner, owner_id) do
    case Storage.get(config, owner_key(owner, owner_id)) do
      nil -> []
      json -> JSON.decode!(json)
    end
  end

  defp encode(key), do: JSON.encode!(key)

  defp decode(json) do
    json
    |> JSON.decode!()
    |> Map.new(fn {field, value} -> {String.to_existing_atom(field), value} end)
    |> Map.new(fn
      {field, value} when field in @times and is_binary(value) ->
        {:ok, time, _offset} = DateTime.from_iso8601(value)
        {field, time}

      pair ->
        pair
    end)
  end

  defp record_key(id), do: "api-key:#{id}"
  defp hash_key(hash), do: "api-key:hash:#{hash}"
  defp owner_key(owner, id), do: "api-key:#{owner}:#{id}"
  defp uses_key(key, period), do: "api-key:uses:#{key.id}:#{period}"
end
