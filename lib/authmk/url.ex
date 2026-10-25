defmodule Authmk.URL do
  @moduledoc false
  # Builds links to auth endpoints and appends query params to redirect URLs.

  alias Authmk.Context

  @doc "Absolute URL of an auth endpoint. `nil` query values are left out."
  @spec endpoint(Context.t(), String.t(), keyword()) :: String.t()
  def endpoint(%Context{base_url: base_url, config: config}, path, query \\ []) do
    if is_nil(base_url) do
      raise ArgumentError,
            "no base URL for this call: set a base_url fallback for server-side use"
    end

    append_query(base_url <> config.base_path <> path, query)
  end

  @doc """
  Appends query params to a URL that may already have some. Spaces become
  `%20`, not `+`: some providers (Cognito) only read the former.
  """
  @spec append_query(String.t(), keyword()) :: String.t()
  def append_query(url, query) do
    case Enum.reject(query, fn {_key, value} -> is_nil(value) end) do
      [] -> url
      query -> url <> separator(url) <> URI.encode_query(query, :rfc3986)
    end
  end

  defp separator(url), do: if(String.contains?(url, "?"), do: "&", else: "?")
end
