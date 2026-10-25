defmodule Authmk.OAuth.Tokens do
  @moduledoc "Tokens from a provider's token endpoint."

  defstruct [
    :access_token,
    :refresh_token,
    :id_token,
    :token_type,
    :access_token_expires_at,
    :refresh_token_expires_at,
    # The ID token's claims, once verified against the provider's keys.
    :claims,
    scopes: [],
    raw: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Builds tokens from a token endpoint's JSON response. `expires_in` is the
  access token lifetime to assume when the response doesn't say.
  """
  @spec from_response(map(), pos_integer() | nil) :: t()
  def from_response(body, expires_in \\ nil) when is_map(body) do
    %__MODULE__{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      id_token: body["id_token"],
      token_type: body["token_type"],
      access_token_expires_at: expires_at(body["expires_in"] || expires_in),
      refresh_token_expires_at: expires_at(body["refresh_token_expires_in"]),
      scopes: scopes(body["scope"]),
      raw: body
    }
  end

  @doc "Account attributes for these tokens."
  @spec account_attrs(t()) :: map()
  def account_attrs(%__MODULE__{} = tokens) do
    %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      id_token: tokens.id_token,
      access_token_expires_at: tokens.access_token_expires_at,
      refresh_token_expires_at: tokens.refresh_token_expires_at,
      scope: if(tokens.scopes == [], do: nil, else: Enum.join(tokens.scopes, ","))
    }
  end

  defp expires_at(seconds) when is_integer(seconds) and seconds > 0,
    do: DateTime.add(DateTime.utc_now(), seconds)

  defp expires_at(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} -> expires_at(seconds)
      _ -> nil
    end
  end

  defp expires_at(_missing), do: nil

  # Providers separate scopes with spaces or commas.
  defp scopes(scope) when is_binary(scope), do: String.split(scope, [" ", ","], trim: true)
  defp scopes(scopes) when is_list(scopes), do: scopes
  defp scopes(_missing), do: []
end
