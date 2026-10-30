defmodule Authmk.RateLimit do
  @moduledoc """
  Fixed-window rate limiting per client IP and endpoint path.

  Each endpoint can declare a default rule (sign-in and sign-up are stricter);
  the `rate_limit: [rules: %{path => [window: s, max: n] | false}]` config
  overrides it. Everything else uses the global `window` and `max`.

  Counters live in memory (the default, per node), in secondary storage
  (shared between nodes), or in the database with
  `Authmk.Plugins.DatabaseRateLimit`.

  IPv6 clients are grouped by their /64 prefix, since one client usually owns
  the whole block.
  """

  alias Authmk.{Context, Error, Request, Storage}
  alias Authmk.Plugins.DatabaseRateLimit

  @doc "`:ok`, or a `:rate_limited` error with `retry_after` seconds in its details."
  @spec check(Context.t()) :: :ok | {:error, Error.t()}
  def check(%Context{config: config, endpoint: endpoint} = ctx) do
    with true <- config.rate_limit[:enabled],
         {window, max} <- rule(config, endpoint),
         count = increment(ctx, key(ctx, window), window),
         true <- count > max do
      {:error, Error.new(:rate_limited, %{retry_after: retry_after(window)})}
    else
      _allowed -> :ok
    end
  end

  @doc """
  Counts a hit on `key`, whoever sends it: `:ok` for the first `max` in
  each `window` of seconds, then a `:rate_limited` error. For limits on
  something other than the client, like codes sent to one phone number.
  Uses the configured rate limit storage, even with rate limiting off.
  """
  @spec check_key(Context.t(), String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, Error.t()}
  def check_key(ctx, key, window, max) do
    window_index = div(System.system_time(:second), window)

    if increment(ctx, "rate-limit:key:#{key}:#{window_index}", window) > max,
      do: {:error, Error.new(:rate_limited, %{retry_after: retry_after(window)})},
      else: :ok
  end

  defp increment(%Context{config: config} = ctx, key, window) do
    case config.rate_limit[:storage] do
      :memory -> Storage.ETS.increment([table: Storage.ETS.table(config.auth)], key, window)
      :secondary_storage -> Storage.increment(config, key, window)
      :database -> DatabaseRateLimit.increment(ctx, key, window)
    end
  end

  # One key per client, path and window, so each window starts a new counter.
  defp key(ctx, window) do
    window_index = div(System.system_time(:second), window)
    "rate-limit:#{client(ctx)}:#{ctx.endpoint.path}:#{window_index}"
  end

  # `{window, max}` for the endpoint, or `nil` when rate limiting is off for it.
  defp rule(config, endpoint) do
    case Map.fetch(config.rate_limit[:rules], endpoint.path) do
      {:ok, false} -> nil
      {:ok, rule} -> with_defaults(config, rule)
      :error -> with_defaults(config, endpoint.rate_limit || [])
    end
  end

  defp with_defaults(config, rule) do
    {Keyword.get(rule, :window, config.rate_limit[:window]),
     Keyword.get(rule, :max, config.rate_limit[:max])}
  end

  defp client(ctx) do
    case Request.client_address(ctx) do
      nil -> "unknown"
      {a, b, c, d, _, _, _, _} -> "#{:inet.ntoa({a, b, c, d, 0, 0, 0, 0})}/64"
      ipv4 -> "#{:inet.ntoa(ipv4)}"
    end
  end

  defp retry_after(window) do
    now = System.system_time(:second)
    (div(now, window) + 1) * window - now
  end
end
