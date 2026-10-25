defmodule Authmk.RateLimit do
  @moduledoc """
  Fixed-window rate limiting per client IP and endpoint path.

  Each endpoint can declare a default rule (sign-in and sign-up are stricter);
  the `rate_limit: [rules: %{path => [window: s, max: n] | false}]` config
  overrides it. Everything else uses the global `window` and `max`.

  IPv6 clients are grouped by their /64 prefix, since one client usually owns
  the whole block.
  """

  alias Authmk.{Context, Error, Request}
  alias Authmk.Storage.ETS

  @doc "Name of the auth module's rate-limit storage."
  @spec storage(module()) :: atom()
  def storage(auth), do: Module.concat(auth, RateLimitStorage)

  @doc "`:ok`, or a `:rate_limited` error with `retry_after` seconds in its details."
  @spec check(Context.t()) :: :ok | {:error, Error.t()}
  def check(%Context{config: config, endpoint: endpoint} = ctx) do
    with true <- config.rate_limit[:enabled],
         {window, max} <- rule(config, endpoint),
         count = ETS.increment(storage(config.auth), {client_key(ctx), endpoint.path}, window),
         true <- count > max do
      {:error, Error.new(:rate_limited, %{retry_after: retry_after(window)})}
    else
      _allowed -> :ok
    end
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

  defp client_key(ctx) do
    case Request.client_address(ctx) do
      {a, b, c, d, _, _, _, _} -> {:ipv6_64, a, b, c, d}
      address -> address
    end
  end

  defp retry_after(window) do
    now = System.system_time(:second)
    (div(now, window) + 1) * window - now
  end
end
