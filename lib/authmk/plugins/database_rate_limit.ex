defmodule Authmk.Plugins.DatabaseRateLimit do
  @moduledoc """
  Keeps rate-limit counters in the database, so every node shares them
  without extra infrastructure.

      use Authmk,
        plugins: [Authmk.Plugins.DatabaseRateLimit, ...],
        rate_limit: [storage: :database]

  It adds a `rate_limits` table. Each check costs a few small queries, so
  prefer secondary storage (Redis) under heavy traffic.
  """

  use Authmk.Plugin

  import Ecto.Query

  alias Authmk.{Context, Store}

  @impl true
  def schema(_opts) do
    %{
      rate_limit: [
        plural: "rate_limits",
        timestamps: false,
        fields: [
          key: [type: :string, required: true, unique: true, input: false],
          count: [type: :integer, required: true, default: 0, input: false],
          expires_at: [type: :datetime, required: true, index: true, input: false]
        ]
      ]
    }
  end

  @doc false
  # Increments the counter for `key` (which includes the window) and returns
  # this request's count.
  @spec increment(Context.t(), String.t(), pos_integer()) :: pos_integer()
  def increment(ctx, key, window) do
    case bump_and_read(ctx, key) do
      {:ok, count} ->
        count

      :missing ->
        if create(ctx, key, window) == :created,
          do: 1,
          else: ctx |> bump_and_read(key) |> elem(1)
    end
  end

  # In one transaction, the row stays locked between the increment and the
  # read, so each request reads its own count, not a later one.
  defp bump_and_read(ctx, key) do
    result =
      Store.transaction(ctx, fn ->
        if bump(ctx, key) == 1, do: {:ok, current(ctx, key)}, else: {:error, :missing}
      end)

    with {:error, :missing} <- result, do: :missing
  end

  defp bump(ctx, key) do
    query = from(limit in Store.module(ctx, :rate_limit), where: limit.key == ^key)
    Store.update_all(ctx, :rate_limit, query, inc: [count: 1])
  end

  # The first request of a window inserts the row, outside any transaction:
  # if another request inserted it first, the unique key rejects this insert.
  defp create(ctx, key, window) do
    window_end = (div(System.system_time(:second), window) + 1) * window
    expires_at = DateTime.from_unix!(window_end)

    case Store.insert(ctx, :rate_limit, %{key: key, count: 1, expires_at: expires_at}) do
      {:ok, _limit} ->
        delete_expired(ctx)
        :created

      {:error, _taken} ->
        :taken
    end
  end

  defp current(ctx, key) do
    query =
      from limit in Store.module(ctx, :rate_limit), where: limit.key == ^key, select: limit.count

    Store.one(ctx, :rate_limit, query)
  end

  # Runs when a new window starts, so old counters don't pile up.
  defp delete_expired(ctx) do
    now = DateTime.utc_now()
    Store.delete_all(ctx, :rate_limit, dynamic([limit], limit.expires_at < ^now))
  end
end
