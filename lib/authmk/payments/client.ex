defmodule Authmk.Payments.Client do
  @moduledoc false
  # JSON requests to a payment provider's API, through authmk's outbound
  # HTTP (no redirects, timeouts). Provider errors become one generic
  # Authmk.Error: their details stay out of answers to users.

  alias Authmk.Error
  alias Authmk.OAuth.HTTP

  def request(ctx, method, url, body, headers, name) do
    result =
      case method do
        :get -> HTTP.get(ctx, url, headers)
        :delete -> HTTP.delete(ctx, url, headers)
        :post -> HTTP.post_json(ctx, url, body, headers)
        :patch -> HTTP.request_json(ctx, :patch, url, body, headers)
        :put -> HTTP.request_json(ctx, :put, url, body, headers)
      end

    case result do
      {:ok, status, body} when status in 200..299 ->
        {:ok, body}

      {:ok, _status, _body} ->
        {:error, Error.custom(:payment_provider_error, 502, "#{name} refused the request")}

      {:error, _reason} ->
        {:error, Error.custom(:payment_provider_unavailable, 502, "#{name} can't be reached")}
    end
  end

  @doc false
  def time(nil), do: nil
  def time(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  def time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, time, _offset} -> time
      {:error, _reason} -> nil
    end
  end
end
