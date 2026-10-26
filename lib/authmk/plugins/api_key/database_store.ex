defmodule Authmk.Plugins.APIKey.DatabaseStore do
  @moduledoc false
  # API keys in the `api_key` table. Usage and rate limits are conditional
  # updates, so concurrent requests can't go over them.

  import Ecto.Query

  alias Authmk.Store

  @json [:permissions, :metadata]

  def insert(ctx, attrs) do
    with {:ok, record} <- Store.insert(ctx, :api_key, encode(attrs)), do: {:ok, to_map(record)}
  end

  def get(ctx, id), do: ctx |> safe_get(id: id) |> to_map()
  def get_by_hash(ctx, hash), do: ctx |> safe_get(key: hash) |> to_map()

  def list(ctx, owner, owner_id),
    do: ctx |> Store.all(:api_key, [{owner, owner_id}], limit: 1000) |> Enum.map(&to_map/1)

  def update(ctx, %{id: id}, attrs) do
    with %{} = record <- safe_get(ctx, id: id),
         {:ok, record} <- Store.update(ctx, :api_key, record, encode(attrs)) do
      {:ok, to_map(record)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def delete(ctx, %{id: id}) do
    _count = Store.delete_all(ctx, :api_key, id: id)
    :ok
  end

  def delete_expired(ctx, now) do
    Store.delete_all(
      ctx,
      :api_key,
      dynamic([k], not is_nil(k.expires_at) and k.expires_at < ^now)
    )
  end

  # One use: from the remaining uses (refilled when the interval has
  # passed), and within the rate limit.
  def use(ctx, key, now) do
    with :ok <- take_use(ctx, key, now),
         :ok <- within_rate_limit(ctx, key, now) do
      set(ctx, key, last_request_at: now)
      {:ok, get(ctx, key.id)}
    end
  end

  defp take_use(_ctx, %{remaining: nil}, _now), do: :ok

  defp take_use(ctx, key, now) do
    cond do
      due_refill?(key, now) and refill(ctx, key, now) -> :ok
      count(ctx, key, dynamic([k], k.remaining > 0), inc: [remaining: -1]) == 1 -> :ok
      true -> {:error, :usage_exceeded}
    end
  end

  defp due_refill?(%{refill_interval: interval, refill_amount: amount} = key, now)
       when is_integer(interval) and is_integer(amount),
       do:
         key.remaining <= 0 and
           DateTime.compare(DateTime.add(key.last_refill_at || key.inserted_at, interval), now) !=
             :gt

  defp due_refill?(_key, _now), do: false

  # Only one request refills: the one that still sees the old refill time.
  defp refill(ctx, key, now) do
    condition =
      case key.last_refill_at do
        nil -> dynamic([k], is_nil(k.last_refill_at))
        at -> dynamic([k], k.last_refill_at == ^at)
      end

    count(ctx, key, condition, set: [remaining: key.refill_amount - 1, last_refill_at: now]) == 1
  end

  defp within_rate_limit(_ctx, %{rate_limit_enabled: false}, _now), do: :ok

  defp within_rate_limit(ctx, key, now) do
    window_start = DateTime.add(now, -key.rate_limit_time_window)

    if new_window?(key, window_start) and start_window(ctx, key, window_start, now),
      do: :ok,
      else: increment(ctx, key)
  end

  defp new_window?(%{request_window_started_at: nil}, _window_start), do: true

  defp new_window?(%{request_window_started_at: started}, window_start),
    do: DateTime.before?(started, window_start)

  # Only one request starts a new window: the one that still sees the old one.
  defp start_window(ctx, key, window_start, now) do
    condition =
      dynamic(
        [k],
        is_nil(k.request_window_started_at) or k.request_window_started_at < ^window_start
      )

    count(ctx, key, condition, set: [request_count: 1, request_window_started_at: now]) == 1
  end

  defp increment(ctx, key) do
    max = key.rate_limit_max

    if count(ctx, key, dynamic([k], k.request_count < ^max), inc: [request_count: 1]) == 1,
      do: :ok,
      else: {:error, :rate_limited}
  end

  defp count(ctx, %{id: id}, condition, updates) do
    query = from(k in Store.module(ctx, :api_key), where: k.id == ^id, where: ^condition)
    Store.update_all(ctx, :api_key, query, updates)
  end

  defp set(ctx, %{id: id}, values) do
    query = from(k in Store.module(ctx, :api_key), where: k.id == ^id)
    _count = Store.update_all(ctx, :api_key, query, set: values)
    :ok
  end

  defp safe_get(ctx, clauses) do
    Store.get_by(ctx, :api_key, clauses)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp encode(attrs) do
    Enum.reduce(@json, attrs, fn field, attrs ->
      case attrs do
        %{^field => value} when is_map(value) -> Map.put(attrs, field, JSON.encode!(value))
        _other -> attrs
      end
    end)
  end

  defp to_map(nil), do: nil

  defp to_map(record) do
    record
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    # Associations (user, service account) are never loaded here.
    |> Map.reject(fn {_field, value} -> match?(%Ecto.Association.NotLoaded{}, value) end)
    |> Map.new(fn
      {field, value} when field in @json and is_binary(value) -> {field, JSON.decode!(value)}
      pair -> pair
    end)
  end
end
