defmodule Authmk.Plugins.OAuthProvider.ClientMetadataDocuments do
  @moduledoc false
  # Client ID metadata documents: a client's `client_id` is an HTTPS URL,
  # and its registration is the JSON document there. No registration step;
  # the document is fetched when the client shows up, stored, and fetched
  # again once it expires.
  #
  # The URL is chosen by whoever sends the request, so fetching it is
  # guarded: HTTPS only, no redirects, 5 KB at most, 5 seconds at most, and
  # never to loopback, private or link-local addresses. Clients found this
  # way can't hold secrets: they're public, or use `private_key_jwt`.

  alias Authmk.OAuth.{HTTP, PublicHost}
  alias Authmk.Plugins.OAuthProvider.Config
  alias Authmk.Store

  @max_bytes 5_000
  @min_ttl 300
  @max_ttl 24 * 60 * 60
  @default_ttl 3600
  @secret_methods ["client_secret_basic", "client_secret_post"]

  @doc "Whether `client_id` names a metadata document (and they're enabled)."
  def document?(ctx, client_id) do
    Config.opts(ctx)[:client_id_metadata_documents] and String.starts_with?(client_id, "https://")
  end

  @doc """
  The client a document describes: stored, or fetched when stale; `nil`
  when it can't be had. `create` and `update` register it (`Clients`').
  """
  def fetch(ctx, client_id, create, update) do
    stored = Store.get_by(ctx, :oauth_client, client_id: client_id)
    now = DateTime.utc_now()

    if stored && stored.metadata_document_expires_at &&
         DateTime.after?(stored.metadata_document_expires_at, now),
       do: stored,
       else: refresh(ctx, client_id, stored, {create, update})
  end

  # Fails closed: a document that can't be fetched again isn't trusted.
  defp refresh(ctx, client_id, stored, register) do
    with :ok <- valid_url?(client_id),
         :ok <- public_host(ctx, URI.parse(client_id).host),
         {:ok, 200, body, headers} <- HTTP.get_limited(ctx, client_id, @max_bytes),
         {:ok, %{} = document} <- JSON.decode(body),
         :ok <- check_document(document, client_id),
         {:ok, client} <- save(ctx, register, stored, client_id, document, ttl(headers)) do
      client
    else
      _unavailable -> nil
    end
  end

  # The draft's rules: an HTTPS URL with a path, nothing that could make two
  # strings name the same client.
  defp valid_url?(url) do
    uri = URI.parse(url)

    if https_with_host?(uri) and plain?(uri) and byte_size(url) <= 255,
      do: :ok,
      else: :error
  end

  defp https_with_host?(uri), do: uri.scheme == "https" and uri.host not in [nil, ""]

  defp plain?(uri) do
    segments = String.split(uri.path || "", "/", trim: true)

    is_nil(uri.userinfo) and is_nil(uri.fragment) and is_nil(uri.query) and segments != [] and
      not Enum.any?(segments, &(&1 in [".", ".."]))
  end

  defp public_host(ctx, host), do: PublicHost.check(host, Config.opts(ctx)[:resolve_host])

  defp check_document(document, client_id) do
    cond do
      document["client_id"] != client_id -> :error
      Map.has_key?(document, "client_secret") -> :error
      document["token_endpoint_auth_method"] in @secret_methods -> :error
      true -> :ok
    end
  end

  defp save(ctx, {create, update}, stored, client_id, document, ttl) do
    metadata = Map.put_new(document, "token_endpoint_auth_method", "none")
    expires_at = DateTime.add(DateTime.utc_now(), ttl)

    result =
      case stored do
        nil -> create.(ctx, metadata, %{client_id: client_id})
        client -> update.(ctx, client, metadata)
      end

    with {:ok, client, _no_secret} <- normalize(result),
         do: Store.update(ctx, :oauth_client, client, %{metadata_document_expires_at: expires_at})
  end

  defp normalize({:ok, client, secret}), do: {:ok, client, secret}
  defp normalize({:ok, client}), do: {:ok, client, nil}
  defp normalize(error), do: error

  # How long to keep it: the server's `max-age`, within bounds.
  defp ttl(headers) do
    max_age =
      headers
      |> Map.get("cache-control", [])
      |> Enum.find_value(fn value ->
        Regex.run(~r/max-age=(\d+)/, value, capture: :all_but_first)
      end)

    case max_age do
      [seconds] -> seconds |> String.to_integer() |> max(@min_ttl) |> min(@max_ttl)
      nil -> @default_ttl
    end
  end
end
