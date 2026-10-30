defmodule Authmk.Plug.WellKnown do
  @moduledoc """
  Serves discovery documents at your app's root, where OAuth and MCP
  clients look for them, for `Authmk.Plugins.OAuthProvider`:

    * `/.well-known/oauth-authorization-server` (RFC 8414), also with the
      issuer's path after it (`.../oauth-authorization-server/auth`)
    * `/.well-known/openid-configuration`, likewise
    * `/.well-known/oauth-protected-resource` (RFC 9728) for each of your
      `protected_resources`, with the resource's path after it

  Put it early in your endpoint or router:

      plug Authmk.Plug.WellKnown,
        auth: MyApp.Auth,
        protected_resources: [
          [resource: "https://example.com/mcp", scopes: ["openid", "profile"], name: "My MCP server"]
        ]

  Each resource must be one of the provider's `resources`. Protect it with
  `Authmk.Plug.RequireAccessToken`, passing its metadata URL as
  `resource_metadata`, so clients without a token find their way.

  Other requests pass through. Any origin may read these documents (CORS).
  """

  @behaviour Plug

  import Plug.Conn

  alias Authmk.{BaseURL, Context}
  alias Authmk.Plugins.OAuthProvider
  alias Authmk.Plugins.OAuthProvider.{Assertions, Config, Metadata}

  @impl true
  def init(opts) do
    resources =
      for resource <- Keyword.get(opts, :protected_resources, []) do
        resource = Map.new(resource)
        url = Map.fetch!(resource, :resource)
        Map.put(resource, :path, "/.well-known/oauth-protected-resource" <> path_suffix(url))
      end

    %{auth: Keyword.fetch!(opts, :auth), resources: resources}
  end

  @impl true
  def call(%Plug.Conn{method: method, request_path: "/.well-known/" <> _} = conn, opts)
      when method in ["GET", "OPTIONS"] do
    case document(conn, opts) do
      nil -> conn
      _document when method == "OPTIONS" -> conn |> cors() |> send_resp(204, "") |> halt()
      document -> conn |> cors() |> json(document) |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp document(conn, %{auth: auth, resources: resources}) do
    ctx = context(auth, conn)
    issuer_path = path_suffix(Config.issuer(ctx))

    case conn.request_path do
      path
      when path in [
             "/.well-known/oauth-authorization-server",
             "/.well-known/oauth-authorization-server" <> issuer_path
           ] ->
        Metadata.document(ctx, :oauth)

      path
      when path in [
             "/.well-known/openid-configuration",
             "/.well-known/openid-configuration" <> issuer_path
           ] ->
        Metadata.document(ctx, :openid)

      path ->
        resources |> Enum.find(&(&1.path == path)) |> resource_document(ctx)
    end
  end

  # RFC 9728 2.
  defp resource_document(nil, _ctx), do: nil

  defp resource_document(resource, ctx) do
    %{
      resource: resource.resource,
      authorization_servers: [Config.issuer(ctx)],
      scopes_supported: resource[:scopes],
      resource_name: resource[:name],
      bearer_methods_supported: ["header"],
      dpop_signing_alg_values_supported: Assertions.algorithms()
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp context(auth, conn) do
    config = auth.config()

    base_url =
      case BaseURL.resolve(config, conn) do
        {:ok, base_url} -> base_url
        _unknown_host -> nil
      end

    %{Context.new(config) | conn: conn, base_url: base_url}
    |> Context.put_private(:oauth_provider_plugin, OAuthProvider)
  end

  # "https://example.com/mcp" -> "/mcp"; no path -> "".
  defp path_suffix(url) do
    case URI.parse(url).path do
      path when path in [nil, "", "/"] -> ""
      path -> String.trim_trailing(path, "/")
    end
  end

  defp cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
  end

  defp json(conn, document) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(document))
  end
end
