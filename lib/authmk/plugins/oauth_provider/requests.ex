defmodule Authmk.Plugins.OAuthProvider.Requests do
  @moduledoc false
  # Checks an authorization request's params, for a client already known
  # to be registered with that redirect URI.

  alias Authmk.Plugins.OAuthProvider.Clients

  @doc "`{:ok, scopes}`, or `{:error, code, description}` for the client."
  def check(_ctx, client, params, opts) do
    with :ok <- check_params(client, params, opts),
         {:ok, scopes} <- check_scopes(client, params, opts) do
      check_pkce(client, params, scopes)
    end
  end

  defp check_params(client, params, opts) do
    cond do
      not resource_allowed?(params["resource"], opts) ->
        {:error, "invalid_target", "Unknown resource"}

      max_age(params["max_age"]) == :invalid ->
        {:error, "invalid_request", "max_age must be a number of seconds"}

      params["response_type"] != "code" ->
        {:error, "unsupported_response_type", "Only the code response type is supported"}

      "authorization_code" not in Clients.list(client.grant_types) ->
        {:error, "unauthorized_client", "The client can't use the authorization code grant"}

      true ->
        :ok
    end
  end

  defp check_scopes(client, params, opts) do
    scopes = String.split(params["scope"] || "", " ", trim: true)

    allowed =
      case Clients.list(client.scopes) do
        [] -> opts[:scopes]
        allowed -> allowed
      end

    cond do
      scopes == [] ->
        {:error, "invalid_scope", "scope is required"}

      Enum.any?(scopes, &(&1 not in allowed)) ->
        {:error, "invalid_scope", "The client can't ask for these scopes"}

      true ->
        {:ok, scopes}
    end
  end

  # S256 only: `plain` gives nothing against an intercepted code.
  defp check_pkce(client, params, scopes) do
    challenge = params["code_challenge"]

    cond do
      is_nil(challenge) and client.require_pkce ->
        {:error, "invalid_request", "PKCE is required: send code_challenge"}

      is_nil(challenge) ->
        {:ok, scopes}

      params["code_challenge_method"] != "S256" ->
        {:error, "invalid_request", "code_challenge_method must be S256"}

      not Regex.match?(~r/\A[A-Za-z0-9\-._~]{43,128}\z/, challenge) ->
        {:error, "invalid_request", "code_challenge is malformed"}

      true ->
        {:ok, scopes}
    end
  end

  @doc "Whether `resource` (or no resource) may be asked for."
  def resource_allowed?(nil, _opts), do: true
  def resource_allowed?(resource, opts) when is_binary(resource), do: resource in opts[:resources]
  def resource_allowed?(_resource, _opts), do: false

  def max_age(nil), do: nil
  def max_age(value) when is_integer(value) and value >= 0, do: value

  def max_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _invalid -> :invalid
    end
  end

  def max_age(_value), do: :invalid
end
