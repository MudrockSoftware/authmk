defmodule Authmk.Plugins.OAuthProvider.Errors do
  @moduledoc false
  # OAuth's own error responses (RFC 6749 5.2), never cached.

  alias Authmk.Context

  @doc "A JSON OAuth error."
  def json(ctx, error, description \\ nil, status \\ 400) do
    body =
      Map.reject(%{error: error, error_description: description}, fn {_k, v} -> is_nil(v) end)

    {:json, status, body, no_store(ctx)}
  end

  @doc "The client failed to authenticate (401, as RFC 6749 asks)."
  def invalid_client(ctx) do
    ctx
    |> Context.put_resp_header("www-authenticate", ~s(Basic realm="oauth"))
    |> json("invalid_client", "Client authentication failed", 401)
  end

  @doc "Responses with tokens or secrets must not be stored by caches."
  def no_store(ctx) do
    ctx
    |> Context.put_resp_header("cache-control", "no-store")
    |> Context.put_resp_header("pragma", "no-cache")
  end
end
