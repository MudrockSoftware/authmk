defmodule Authmk.Plugins.OAuthProvider do
  @moduledoc """
  Makes your app an OAuth 2.1 authorization server and OpenID Connect
  provider: other apps sign their users in with your accounts ("Sign in
  with Acme") and get tokens for your APIs.

      use Authmk,
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.JWT, algorithm: "RS256"},
          {Authmk.Plugins.OAuthProvider, login_page: "/sign-in", consent_page: "/consent"}
        ],
        ...

  It needs `Authmk.Plugins.JWT`, whose keys sign ID tokens. Most OpenID
  Connect clients expect RS256.

  | Method | Path | Session |
  |---|---|---|
  | GET | `/.well-known/openid-configuration` | none |
  | GET | `/.well-known/oauth-authorization-server` | none |
  | GET | `/oauth2/authorize` | optional |
  | POST | `/oauth2/continue` | required |
  | POST | `/oauth2/consent` | required |
  | POST | `/oauth2/token` | none (client authentication) |
  | POST | `/oauth2/introspect` | none (client authentication) |
  | POST | `/oauth2/revoke` | none (client authentication) |
  | GET, POST | `/oauth2/userinfo` | none (access token) |
  | POST | `/oauth2/register` | optional (`allow_dynamic_client_registration`) |
  | POST | `/oauth2/create-client` | required |
  | GET | `/oauth2/get-client`, `/oauth2/get-clients` | required |
  | POST | `/oauth2/update-client`, `/oauth2/delete-client` | required |
  | POST | `/oauth2/client/rotate-secret` | required |
  | GET | `/oauth2/public-client` | none |

  ## The flow

  A client sends the user to `/oauth2/authorize` (authorization code with
  PKCE; S256 only). If they aren't signed in, they go to your `login_page`
  with `client_id` and `oauth_query`; after signing in, your page posts
  `oauth_query` to `/oauth2/continue` and follows the `url` it gets. If
  they haven't agreed to the scopes yet, your `consent_page` gets
  `client_id`, `scope` and `oauth_query`, shows what the client asks for
  (`/oauth2/public-client`), and posts `accept` to `/oauth2/consent`. The
  client then trades the code at `/oauth2/token`.

  `oauth_query` is signed and expires after 10 minutes, so the request
  can't be changed on the way. Tokens, codes and client secrets are stored
  hashed. Refresh tokens (scope `offline_access`) rotate on every use; see
  `refresh_token_reuse_interval`.

  Register clients from server code with `create_client/3`, or let users
  do it with the client endpoints. Check access tokens in your APIs with
  `verify_access_token/3`.

  ## MCP servers

  MCP clients find and use this server on their own:

      {Authmk.Plugins.OAuthProvider,
       login_page: "/sign-in",
       consent_page: "/consent",
       resources: ["https://example.com/mcp"],
       allow_dynamic_client_registration: true,
       allow_unauthenticated_client_registration: true}

  Serve the discovery documents with `Authmk.Plug.WellKnown`, and protect
  the MCP route with `Authmk.Plug.RequireAccessToken` (`resource:` the MCP
  URL, `resource_metadata:` its metadata URL). A client without a token
  gets a 401 pointing at the metadata, finds this server, registers itself
  (from any origin: registration, token and user info allow CORS), and asks
  for a token for the MCP server's URL. For your own CLI tools, add
  `Authmk.Plugins.DeviceAuthorization`: they get tokens with the device code
  grant, with the same `resource`.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.OAuthProvider.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{BaseURL, Context, Endpoint, Error}
  alias Authmk.Plugins.JWT

  alias Authmk.Plugins.OAuthProvider.{
    Authorize,
    ClientEndpoints,
    Clients,
    Introspection,
    Logout,
    Metadata,
    Options,
    PushedRequests,
    Schema,
    TokenEndpoint,
    Tokens,
    Userinfo
  }

  @impl true
  def init(opts) do
    opts =
      opts
      |> NimbleOptions.validate!(Options.schema())
      |> Keyword.update!(:resources, fn
        resources when is_function(resources, 0) -> resources.()
        resources -> resources
      end)

    if opts[:pairwise_secret] && byte_size(opts[:pairwise_secret]) < 32,
      do:
        raise(
          ArgumentError,
          "Authmk.Plugins.OAuthProvider: pairwise_secret must be at least 32 bytes"
        )

    opts
  end

  @impl true
  def depends_on, do: [JWT]

  @impl true
  def schema(_opts), do: Schema.models()

  @impl true
  def endpoints(opts) do
    client_id = [client_id: [type: :string, required: true]]

    [
      endpoint(
        :openid_configuration,
        :get,
        "/.well-known/openid-configuration",
        {Metadata, :openid_configuration},
        cors: true
      ),
      endpoint(
        :oauth_authorization_server,
        :get,
        "/.well-known/oauth-authorization-server",
        {Metadata, :authorization_server},
        cors: true
      ),
      endpoint(:oauth2_authorize, :get, "/oauth2/authorize", {Authorize, :authorize},
        session: :optional
      ),
      endpoint(:oauth2_continue, :post, "/oauth2/continue", {Authorize, :continue},
        session: :required,
        params: [oauth_query: [type: :string, required: true]]
      ),
      endpoint(:oauth2_consent, :post, "/oauth2/consent", {Authorize, :consent},
        session: :required,
        params: [
          oauth_query: [type: :string, required: true],
          accept: [type: :boolean, required: true],
          scope: [type: :string]
        ]
      ),
      # These use no cookies, so there's no CSRF to stop, and browser apps on
      # any origin may call them.
      endpoint(:oauth2_token, :post, "/oauth2/token", {TokenEndpoint, :token},
        origin_check: false,
        cors: true,
        rate_limit: [window: 60, max: 60]
      ),
      endpoint(:oauth2_end_session, :get, "/oauth2/end-session", {Logout, :end_session},
        session: :optional
      ),
      endpoint(
        :oauth2_end_session_confirm,
        :post,
        "/oauth2/end-session/confirm",
        {Logout, :confirm_end_session},
        session: :optional,
        params: [logout_query: [type: :string, required: true]]
      ),
      endpoint(:oauth2_par, :post, "/oauth2/par", {PushedRequests, :push}, origin_check: false),
      endpoint(:oauth2_introspect, :post, "/oauth2/introspect", {Introspection, :introspect},
        origin_check: false
      ),
      endpoint(:oauth2_revoke, :post, "/oauth2/revoke", {Introspection, :revoke},
        origin_check: false,
        cors: true
      ),
      endpoint(:oauth2_userinfo, :get, "/oauth2/userinfo", {Userinfo, :userinfo},
        origin_check: false,
        cors: true
      ),
      endpoint(:oauth2_userinfo_post, :post, "/oauth2/userinfo", {Userinfo, :userinfo},
        origin_check: false,
        cors: true
      ),
      endpoint(:oauth2_create_client, :post, "/oauth2/create-client", {ClientEndpoints, :create},
        session: :required
      ),
      endpoint(:oauth2_get_client, :get, "/oauth2/get-client", {ClientEndpoints, :get},
        session: :required,
        params: client_id
      ),
      endpoint(:oauth2_get_clients, :get, "/oauth2/get-clients", {ClientEndpoints, :list},
        session: :required
      ),
      endpoint(:oauth2_update_client, :post, "/oauth2/update-client", {ClientEndpoints, :update},
        session: :required,
        params: client_id ++ [update: [type: :map, required: true]]
      ),
      endpoint(:oauth2_delete_client, :post, "/oauth2/delete-client", {ClientEndpoints, :delete},
        session: :required,
        params: client_id
      ),
      endpoint(
        :oauth2_rotate_client_secret,
        :post,
        "/oauth2/client/rotate-secret",
        {ClientEndpoints, :rotate_secret},
        session: :required,
        params: client_id
      ),
      endpoint(:oauth2_public_client, :get, "/oauth2/public-client", {ClientEndpoints, :public},
        params: client_id
      )
    ] ++ registration(opts)
  end

  # Back-channel logout. Called from any endpoint that ends sessions, so the
  # handler learns which plugin it serves from the context.
  @impl true
  def sessions_ended(user_id, sessions, ctx) do
    ctx = Context.put_private(ctx, :oauth_provider_plugin, __MODULE__)
    Logout.sessions_ended(ctx, user_id, sessions)
  end

  defp registration(opts) do
    if opts[:allow_dynamic_client_registration],
      do: [
        # Open to any origin, as MCP clients in browsers need; a session
        # counts only from trusted origins (see ClientEndpoints.register/1).
        endpoint(:oauth2_register, :post, "/oauth2/register", {ClientEndpoints, :register},
          session: :optional,
          origin_check: false,
          cors: true,
          rate_limit: [window: 60, max: 10]
        )
      ],
      else: []
  end

  defp endpoint(name, method, path, handler, opts),
    do: Endpoint.new([name: name, method: method, path: path, handler: handler] ++ opts)

  @doc """
  Registers a client from server code. `metadata` uses RFC 7591's names
  (`"redirect_uris"`, `"client_name"`, `"token_endpoint_auth_method"`...).

  Options: `:user_id` and `:reference_id` (an organization) own it;
  `skip_consent: true` for your own first-party apps, and `:client_id` to
  choose their id (to list it in `trusted_clients`).

  Returns the client's registration, with `client_secret` (for
  confidential clients), which is never shown again.
  """
  @spec create_client(module(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create_client(auth, metadata, opts \\ []) do
    ctx = server_ctx(auth)
    owner = Map.new(Keyword.take(opts, [:user_id, :reference_id, :skip_consent, :client_id]))

    case Clients.create(ctx, metadata, owner) do
      {:ok, client, secret} -> {:ok, Clients.to_metadata(client, secret)}
      {:error, code, description} -> {:error, Clients.error(code, description)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc """
  What a consent page shows about a client: `client_name`, `client_uri`,
  `logo_uri`, `tos_uri`, `policy_uri` and `contacts`. `nil` for unknown or
  disabled clients.
  """
  @spec public_client(module(), String.t()) :: map() | nil
  def public_client(auth, client_id),
    do: ClientEndpoints.public_details(server_ctx(auth), client_id)

  @doc """
  Checks an access token, for your APIs (resource servers in the same app;
  others use `/oauth2/introspect`, or the JWKS for resource tokens).

  Options: `scopes:` it must have, `resource:` it must be for, and
  `dpop_jkt:` the thumbprint of the key a DPoP proof showed (a DPoP-bound
  token is refused without it, and a plain one with it).

  Returns `{:ok, %{client_id:, user_id:, scopes:, resource:, reference_id:,
  expires_at:, session_id:}}` (no user for client credentials tokens), or
  `{:error, %Authmk.Error{}}` with code `:invalid_token` or
  `:insufficient_scope`.
  """
  @spec verify_access_token(module(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def verify_access_token(auth, token, opts \\ []) do
    ctx = server_ctx(auth)

    with {access, client} <- Tokens.find_access(ctx, token),
         :ok <- check_resource(opts[:resource], access.resource),
         :ok <- check_binding(access.dpop_jkt, opts[:dpop_jkt]),
         scopes = Clients.list(access.scopes),
         true <- Enum.all?(opts[:scopes] || [], &(&1 in scopes)) || :insufficient_scope do
      {:ok,
       %{
         client_id: client.client_id,
         user_id: access.user_id,
         scopes: scopes,
         resource: access.resource,
         reference_id: access.reference_id,
         expires_at: access.expires_at,
         session_id: access.session_id
       }}
    else
      :insufficient_scope ->
        {:error, Error.custom(:insufficient_scope, 403, "The token lacks a scope")}

      nil ->
        {:error, Error.custom(:invalid_token, 401, "The token is invalid or expired")}
    end
  end

  # The key a DPoP-bound token is tied to; plain tokens, none.
  defp check_binding(jkt, jkt), do: :ok
  defp check_binding(_bound, _shown), do: nil

  defp check_resource(nil, _resource), do: :ok
  defp check_resource(resource, resource), do: :ok
  defp check_resource(_wanted, _resource), do: nil

  defp server_ctx(auth) do
    config = auth.config()

    base_url =
      case BaseURL.resolve(config, nil) do
        {:ok, base_url} -> base_url
        _dynamic -> nil
      end

    %{Context.new(config) | base_url: base_url}
    |> Context.put_private(:oauth_provider_plugin, __MODULE__)
  end
end
