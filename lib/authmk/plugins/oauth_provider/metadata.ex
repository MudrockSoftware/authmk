defmodule Authmk.Plugins.OAuthProvider.Metadata do
  @moduledoc false
  # Discovery: OpenID Connect's openid-configuration and OAuth's
  # authorization server metadata (RFC 8414).

  alias Authmk.{Context, URL}
  alias Authmk.Plugins.DeviceAuthorization
  alias Authmk.Plugins.JWT
  alias Authmk.Plugins.OAuthProvider.{Assertions, Config, TokenEndpoint}

  @client_auth_methods ["client_secret_basic", "client_secret_post", "private_key_jwt"]

  def openid_configuration(ctx), do: {:json, 200, document(ctx, :openid), ctx}

  def authorization_server(ctx), do: {:json, 200, document(ctx, :oauth), ctx}

  @doc "A discovery document, after the app's `metadata` function."
  def document(%Context{} = ctx, kind) do
    opts = Config.opts(ctx)
    document = base(ctx, opts) |> Map.merge(if(kind == :openid, do: openid(ctx, opts), else: %{}))

    case opts[:metadata] do
      nil -> document
      change -> change.(document)
    end
  end

  defp base(%Context{config: config} = ctx, opts) do
    device? = DeviceAuthorization in Enum.map(config.plugins, &elem(&1, 0))

    %{
      issuer: Config.issuer(ctx),
      authorization_endpoint: URL.endpoint(ctx, "/oauth2/authorize"),
      token_endpoint: URL.endpoint(ctx, "/oauth2/token"),
      introspection_endpoint: URL.endpoint(ctx, "/oauth2/introspect"),
      revocation_endpoint: URL.endpoint(ctx, "/oauth2/revoke"),
      jwks_uri: JWT.jwks_url(ctx),
      registration_endpoint:
        if(opts[:allow_dynamic_client_registration], do: URL.endpoint(ctx, "/oauth2/register")),
      device_authorization_endpoint: if(device?, do: URL.endpoint(ctx, "/device/code")),
      scopes_supported: opts[:scopes],
      response_types_supported: ["code"],
      response_modes_supported: ["query"],
      grant_types_supported: TokenEndpoint.supported_grants(ctx),
      token_endpoint_auth_methods_supported: @client_auth_methods ++ ["none"],
      token_endpoint_auth_signing_alg_values_supported: Assertions.algorithms(),
      introspection_endpoint_auth_methods_supported: @client_auth_methods,
      revocation_endpoint_auth_methods_supported: @client_auth_methods ++ ["none"],
      pushed_authorization_request_endpoint: URL.endpoint(ctx, "/oauth2/par"),
      require_pushed_authorization_requests: opts[:require_pushed_authorization_requests],
      code_challenge_methods_supported: ["S256"],
      dpop_signing_alg_values_supported: Assertions.algorithms(),
      authorization_response_iss_parameter_supported: true,
      client_id_metadata_document_supported: opts[:client_id_metadata_documents]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp openid(ctx, opts) do
    %{
      userinfo_endpoint: URL.endpoint(ctx, "/oauth2/userinfo"),
      end_session_endpoint: URL.endpoint(ctx, "/oauth2/end-session"),
      backchannel_logout_supported: true,
      backchannel_logout_session_supported: true,
      subject_types_supported:
        if(opts[:pairwise_secret], do: ["public", "pairwise"], else: ["public"]),
      id_token_signing_alg_values_supported: [JWT.algorithm(ctx)],
      claims_supported:
        ~w(sub iss aud exp iat auth_time nonce sid azp name picture updated_at email email_verified),
      prompt_values_supported: ["none", "login", "consent"]
    }
  end
end
