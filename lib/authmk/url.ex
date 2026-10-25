defmodule Authmk.URL do
  @moduledoc false
  # Builds links to auth endpoints and appends query params to redirect URLs.

  alias Authmk.Config

  @doc "Absolute URL of an auth endpoint. `nil` query values are left out."
  @spec endpoint(Config.t(), String.t(), keyword()) :: String.t()
  def endpoint(config, path, query \\ []) do
    append_query(config.base_url <> config.base_path <> path, query)
  end

  @doc "Appends query params to a URL that may already have some."
  @spec append_query(String.t(), keyword()) :: String.t()
  def append_query(url, query) do
    case Enum.reject(query, fn {_key, value} -> is_nil(value) end) do
      [] -> url
      query -> url <> separator(url) <> URI.encode_query(query)
    end
  end

  defp separator(url), do: if(String.contains?(url, "?"), do: "&", else: "?")
end
