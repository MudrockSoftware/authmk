defmodule Authmk.Plugins.OAuthProvider.Clients do
  @moduledoc false
  # OAuth clients: registration (validated like RFC 7591), lookup,
  # authentication at the token endpoint, and redirect URI matching.

  alias Authmk.{Context, Store, Token, URL}
  alias Authmk.Plugins.OAuthProvider.{Assertions, ClientMetadataDocuments, Config}
  alias Authmk.Storage.ETS

  @auth_methods ["client_secret_basic", "client_secret_post", "private_key_jwt", "none"]
  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @device_code "urn:ietf:params:oauth:grant-type:device_code"
  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @grant_types [
    "authorization_code",
    "refresh_token",
    "client_credentials",
    @device_code,
    @jwt_bearer
  ]

  def grant_types, do: @grant_types
  @loopback_hosts ["127.0.0.1", "[::1]", "::1"]

  @doc "Whether a client authenticates (with a secret or its keys)."
  def confidential?(client), do: client.token_endpoint_auth_method != "none"

  defp uses_secret?(method), do: method in ["client_secret_basic", "client_secret_post"]

  @doc "A space-separated list field as a list."
  def list(nil), do: []
  def list(text), do: String.split(text, " ", trim: true)

  defp join([]), do: nil
  defp join(values), do: Enum.join(values, " ")

  @doc """
  Registers a client from RFC 7591 metadata (string keys). `owner` sets
  `user_id`, `reference_id`, `skip_consent` and (from server code, for
  first-party apps) `client_id`, which clients can't choose. Returns the
  client and its secret, shown only now.
  """
  def create(ctx, metadata, owner \\ %{}) do
    with {:ok, attrs} <- validate(ctx, metadata),
         {:ok, client_id} <- client_id(owner[:client_id]) do
      secret = if uses_secret?(attrs.token_endpoint_auth_method), do: Token.generate(32)

      attrs =
        attrs
        |> Map.merge(%{
          client_id: client_id,
          client_secret: secret && Token.hash(secret)
        })
        |> Map.merge(Map.take(owner, [:user_id, :reference_id, :skip_consent]))

      with {:ok, client} <- Store.insert(ctx, :oauth_client, attrs, :internal),
           do: {:ok, client, secret}
    end
  end

  defp client_id(nil), do: {:ok, Token.generate(24)}

  defp client_id(chosen) when is_binary(chosen) do
    # URL characters (RFC 3986): client ID metadata documents use URLs.
    if Regex.match?(~r/\A[A-Za-z0-9._~:\/?\[\]@!$&'()*+,;=%-]{8,255}\z/, chosen),
      do: {:ok, chosen},
      else: invalid("client_id must be 8 to 255 URL characters")
  end

  @doc "Changes a client's metadata. Its kind (public or confidential) stays."
  def update(ctx, client, metadata) do
    current = %{
      "redirect_uris" => list(client.redirect_uris),
      "token_endpoint_auth_method" => client.token_endpoint_auth_method,
      "grant_types" => list(client.grant_types),
      "response_types" => list(client.response_types),
      "application_type" => client.application_type,
      "subject_type" => client.subject_type
    }

    metadata = Map.merge(current, Map.drop(metadata, ["token_endpoint_auth_method"]))

    with {:ok, attrs} <- validate(ctx, metadata) do
      :ok = forget(ctx, client)
      Store.update(ctx, :oauth_client, client, attrs, :internal)
    end
  end

  @doc "A new secret for a confidential client, shown only now."
  def rotate_secret(ctx, client) do
    if uses_secret?(client.token_endpoint_auth_method) do
      secret = Token.generate(32)
      :ok = forget(ctx, client)

      with {:ok, client} <-
             Store.update(ctx, :oauth_client, client, %{client_secret: Token.hash(secret)}),
           do: {:ok, client, secret}
    else
      {:error, "invalid_client_metadata", "This client has no secret"}
    end
  end

  @doc "An enabled client by its `client_id`, or `nil`."
  def fetch(ctx, client_id) when is_binary(client_id) do
    client =
      cond do
        client_id in Config.opts(ctx)[:trusted_clients] ->
          cached(ctx, client_id)

        # Registered from the document: with this module's own create and
        # update, passed in so the two modules don't depend on each other.
        ClientMetadataDocuments.document?(ctx, client_id) ->
          ClientMetadataDocuments.fetch(ctx, client_id, &create/3, &update/3)

        true ->
          load(ctx, client_id)
      end

    case client do
      %{disabled: false} -> client
      _missing_or_disabled -> nil
    end
  end

  def fetch(_ctx, _client_id), do: nil

  defp load(ctx, client_id), do: Store.get_by(ctx, :oauth_client, client_id: client_id)

  # Trusted clients are read on every request of your own apps: kept for a
  # minute on this node.
  @cache_ttl 60

  defp cached(%Context{config: config} = ctx, client_id) do
    table = [table: ETS.table(config.auth)]

    case ETS.get(table, cache_key(client_id)) do
      nil ->
        client = load(ctx, client_id)
        if client, do: :ok = ETS.put(table, cache_key(client_id), client, @cache_ttl)
        client

      client ->
        client
    end
  end

  @doc "Drops a client from the cache, after it changed."
  def forget(%Context{config: config}, client) do
    ETS.delete([table: ETS.table(config.auth)], cache_key(client.client_id))
  end

  defp cache_key(client_id), do: "oauth-client:" <> client_id

  @doc "The scopes a client may ask for: its own, or else the server's."
  def allowed_scopes(ctx, client) do
    case list(client.scopes) do
      [] -> Config.opts(ctx)[:scopes]
      scopes -> scopes
    end
  end

  @doc "Whether the client skips consent: marked so, or one of `trusted_clients`."
  def trusted?(ctx, client),
    do: client.skip_consent or client.client_id in Config.opts(ctx)[:trusted_clients]

  @doc """
  Authenticates the client calling the token, introspection or revocation
  endpoint, with the method it registered. Returns the client, or `:error`.
  """
  def authenticate(%Context{raw_params: %{"client_assertion_type" => @assertion_type}} = ctx),
    do: authenticate_assertion(ctx)

  def authenticate(%Context{conn: conn, raw_params: params} = ctx) do
    case {basic_credentials(conn), params["client_secret"]} do
      {{:ok, _id, _secret}, secret} when is_binary(secret) ->
        :error

      {{:ok, id, secret}, nil} ->
        check(fetch(ctx, id), "client_secret_basic", secret, params)

      {:none, nil} ->
        check(fetch(ctx, params["client_id"]), "none", nil, params)

      {:none, secret} ->
        check(fetch(ctx, params["client_id"]), "client_secret_post", secret, params)

      {:malformed, _secret} ->
        :error
    end
  end

  # private_key_jwt: a JWT the client signed, for this server.
  defp authenticate_assertion(%Context{raw_params: params} = ctx) do
    assertion = params["client_assertion"]

    with nil <- params["client_secret"],
         {:ok, client_id} <- Assertions.issuer(assertion),
         true <- params["client_id"] in [nil, client_id],
         %{token_endpoint_auth_method: "private_key_jwt"} = client <- fetch(ctx, client_id),
         {:ok, _claims} <- Assertions.verify(ctx, client, assertion, audiences(ctx)) do
      {:ok, client}
    else
      _invalid -> :error
    end
  end

  # RFC 7523: the token endpoint, or the issuer (as OpenID Connect allows).
  defp audiences(%Context{endpoint: endpoint} = ctx) do
    issuer = Config.issuer(ctx)

    [issuer, URL.endpoint(ctx, "/oauth2/token")] ++
      if(endpoint, do: [URL.endpoint(ctx, endpoint.path)], else: [])
  end

  # A body client_id must name the same client as the header.
  defp check(nil, _method, _secret, _params), do: :error

  defp check(client, method, secret, params) do
    same_client = params["client_id"] in [nil, client.client_id]

    cond do
      not same_client -> :error
      client.token_endpoint_auth_method != method -> :error
      method == "none" -> {:ok, client}
      secret_matches?(client, secret) -> {:ok, client}
      true -> :error
    end
  end

  defp secret_matches?(%{client_secret: hash}, secret) when is_binary(hash) and is_binary(secret),
    do: Plug.Crypto.secure_compare(Token.hash(secret), hash)

  defp secret_matches?(_client, _secret), do: false

  # RFC 6749 2.3.1: both halves are form-encoded inside the Basic header.
  defp basic_credentials(nil), do: :none

  defp basic_credentials(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Basic " <> encoded] ->
        with {:ok, decoded} <- Base.decode64(String.trim(encoded)),
             [id, secret] <- String.split(decoded, ":", parts: 2) do
          {:ok, URI.decode_www_form(id), URI.decode_www_form(secret)}
        else
          _malformed -> :malformed
        end

      _none ->
        :none
    end
  rescue
    ArgumentError -> :malformed
  end

  @doc """
  Whether `uri` is one of the client's redirect URIs: an exact match, or
  for native apps a loopback URI on any port (RFC 8252). The app's
  `validate_redirect_uri` has the last word.
  """
  def redirect_uri_allowed?(client, uri, opts) when is_binary(uri) do
    registered = list(client.redirect_uris)
    default = uri in registered or native_loopback?(client, uri, registered)

    case opts[:validate_redirect_uri] do
      nil -> default
      validate -> validate.(uri, registered, default) == true
    end
  end

  def redirect_uri_allowed?(_client, _uri, _opts), do: false

  defp native_loopback?(%{application_type: "native"}, uri, registered) do
    case URI.parse(uri) do
      %URI{scheme: "http", host: host} = parsed when host in @loopback_hosts ->
        without_port = URI.to_string(%{parsed | port: nil})
        Enum.any?(registered, &(URI.to_string(%{URI.parse(&1) | port: nil}) == without_port))

      _other ->
        false
    end
  end

  defp native_loopback?(_client, _uri, _registered), do: false

  @doc "The client's registration, as RFC 7591 metadata."
  def to_metadata(client, secret \\ nil) do
    %{
      client_id: client.client_id,
      client_secret: secret,
      client_name: client.name,
      client_uri: client.uri,
      logo_uri: client.icon,
      contacts: list(client.contacts),
      tos_uri: client.tos_uri,
      policy_uri: client.policy_uri,
      redirect_uris: list(client.redirect_uris),
      post_logout_redirect_uris: list(client.post_logout_redirect_uris),
      scope: client.scopes,
      grant_types: list(client.grant_types),
      response_types: list(client.response_types),
      token_endpoint_auth_method: client.token_endpoint_auth_method,
      application_type: client.application_type,
      require_pkce: client.require_pkce,
      dpop_bound_access_tokens: client.dpop_bound_access_tokens,
      subject_type: client.subject_type,
      jwks_uri: client.jwks_uri,
      backchannel_logout_uri: client.backchannel_logout_uri,
      software_id: client.software_id,
      software_version: client.software_version,
      client_id_issued_at: DateTime.to_unix(client.inserted_at),
      client_secret_expires_at: if(uses_secret?(client.token_endpoint_auth_method), do: 0)
    }
    |> Map.reject(fn {_key, value} -> value in [nil, []] end)
  end

  # Registration metadata -> client attrs, or {:error, code, description}.
  defp validate(%Context{} = ctx, metadata) when is_map(metadata) do
    provider_scopes = Config.opts(ctx)[:scopes]

    %{
      method: method,
      application_type: application_type,
      grant_types: grant_types,
      response_types: response_types,
      redirect_uris: redirect_uris,
      scopes: scopes
    } = with_defaults(metadata)

    with :ok <- check_in(method, @auth_methods, "token_endpoint_auth_method"),
         :ok <- check_in(application_type, ["web", "native"], "application_type"),
         :ok <- check_strings(grant_types, "grant_types"),
         :ok <- check_all_in(grant_types, @grant_types, "grant_types"),
         :ok <- check_strings(response_types, "response_types"),
         :ok <- check_all_in(response_types, ["code"], "response_types"),
         :ok <- check_grants(grant_types, response_types, method),
         :ok <- check_redirect_uris(redirect_uris, grant_types, application_type),
         :ok <- check_post_logout_uris(metadata["post_logout_redirect_uris"] || []),
         :ok <- check_all_in(scopes, provider_scopes, "scope"),
         :ok <- check_optional_urls(metadata),
         :ok <- check_keys(method, metadata["jwks"], metadata["jwks_uri"]),
         :ok <- check_subject_type(metadata["subject_type"], redirect_uris, ctx) do
      {:ok,
       %{
         name: metadata["client_name"],
         uri: metadata["client_uri"],
         icon: metadata["logo_uri"],
         contacts: join(List.wrap(metadata["contacts"])),
         tos_uri: metadata["tos_uri"],
         policy_uri: metadata["policy_uri"],
         redirect_uris: join(redirect_uris),
         post_logout_redirect_uris: join(metadata["post_logout_redirect_uris"] || []),
         scopes: join(scopes),
         grant_types: join(grant_types),
         response_types: join(response_types),
         token_endpoint_auth_method: method,
         application_type: application_type,
         # OAuth 2.1: PKCE for everyone, unless a confidential client opts out.
         require_pkce: method == "none" or metadata["require_pkce"] != false,
         dpop_bound_access_tokens: metadata["dpop_bound_access_tokens"] == true,
         jwks_uri: metadata["jwks_uri"],
         jwks: metadata["jwks"] && JSON.encode!(metadata["jwks"]),
         backchannel_logout_uri: metadata["backchannel_logout_uri"],
         software_id: metadata["software_id"],
         software_version: metadata["software_version"],
         software_statement: metadata["software_statement"],
         subject_type: metadata["subject_type"] || "public"
       }}
    end
  end

  defp validate(_ctx, _metadata), do: invalid("The metadata must be a JSON object")

  defp with_defaults(metadata) do
    grant_types = metadata["grant_types"] || ["authorization_code"]

    %{
      method: metadata["token_endpoint_auth_method"] || "client_secret_basic",
      application_type: metadata["application_type"] || "web",
      grant_types: grant_types,
      response_types: metadata["response_types"] || default_response_types(grant_types),
      redirect_uris: metadata["redirect_uris"] || [],
      scopes: list(metadata["scope"])
    }
  end

  defp default_response_types(grant_types),
    do: if("authorization_code" in grant_types, do: ["code"], else: [])

  defp check_in(value, allowed, field),
    do: if(value in allowed, do: :ok, else: invalid("Unsupported #{field}: #{inspect(value)}"))

  defp check_all_in(values, allowed, field) do
    case Enum.reject(values, &(&1 in allowed)) do
      [] -> :ok
      unsupported -> invalid("Unsupported #{field}: #{Enum.join(unsupported, ", ")}")
    end
  end

  defp check_strings(values, field) do
    if is_list(values) and Enum.all?(values, &is_binary/1),
      do: :ok,
      else: invalid("#{field} must be a list of strings")
  end

  defp check_grants(grant_types, response_types, method) do
    cond do
      "authorization_code" in grant_types != "code" in response_types ->
        invalid("The code response type goes with the authorization_code grant")

      method == "none" and ("client_credentials" in grant_types or @jwt_bearer in grant_types) ->
        invalid("Public clients can't use client_credentials or jwt-bearer")

      grant_types == ["refresh_token"] ->
        invalid("refresh_token needs another grant to start from")

      true ->
        :ok
    end
  end

  defp check_redirect_uris(uris, grant_types, application_type) do
    cond do
      not (is_list(uris) and Enum.all?(uris, &is_binary/1)) ->
        {:error, "invalid_redirect_uri", "redirect_uris must be a list of URLs"}

      uris == [] and "authorization_code" in grant_types ->
        {:error, "invalid_redirect_uri", "At least one redirect URI is needed"}

      bad = Enum.find(uris, &(not redirect_uri_valid?(&1, application_type))) ->
        {:error, "invalid_redirect_uri", "Not an allowed redirect URI: #{bad}"}

      true ->
        :ok
    end
  end

  defp check_post_logout_uris(uris) do
    if is_list(uris) and Enum.all?(uris, &(is_binary(&1) and redirect_uri_valid?(&1, "web"))),
      do: :ok,
      else: invalid("post_logout_redirect_uris must be HTTPS (or loopback) URLs")
  end

  # Clients that sign their requests register their public keys, inline or
  # by URL, never both, and never private parts.
  defp check_keys("private_key_jwt", nil, nil),
    do: invalid("private_key_jwt needs jwks or jwks_uri")

  defp check_keys(_method, jwks, uri) when not is_nil(jwks) and not is_nil(uri),
    do: invalid("Send jwks or jwks_uri, not both")

  defp check_keys(_method, nil, _uri), do: :ok

  defp check_keys(_method, %{"keys" => [_ | _] = keys}, nil) do
    if Enum.all?(keys, &(is_map(&1) and is_binary(&1["kty"]) and not Map.has_key?(&1, "d"))),
      do: :ok,
      else: invalid("jwks must hold public keys only")
  end

  defp check_keys(_method, _jwks, _uri), do: invalid("jwks must be a JWKS: {\"keys\": [...]}")

  # Pairwise identifiers are per site, so every redirect URI must be on one.
  defp check_subject_type(type, _uris, _ctx) when type in [nil, "public"], do: :ok

  defp check_subject_type("pairwise", uris, ctx) do
    hosts = uris |> Enum.map(&URI.parse(&1).host) |> Enum.uniq()

    cond do
      is_nil(Config.opts(ctx)[:pairwise_secret]) -> invalid("Pairwise subjects aren't enabled")
      length(hosts) != 1 -> invalid("Pairwise clients need all redirect URIs on one host")
      true -> :ok
    end
  end

  defp check_subject_type(_type, _uris, _ctx),
    do: invalid("subject_type must be public or pairwise")

  defp check_optional_urls(metadata) do
    bad =
      Enum.find(
        ~w(client_uri logo_uri tos_uri policy_uri jwks_uri backchannel_logout_uri),
        fn key ->
          value = metadata[key]
          not is_nil(value) and not (is_binary(value) and https_or_loopback?(URI.parse(value)))
        end
      )

    if bad, do: invalid("#{bad} must be an HTTPS URL"), else: :ok
  end

  # Web apps: HTTPS, or HTTP on loopback for development. Native apps also
  # their own schemes (com.example.app:/callback). Never fragments, and
  # never schemes that run code.
  defp redirect_uri_valid?(uri, application_type) do
    parsed = URI.parse(uri)

    cond do
      parsed.fragment != nil or parsed.scheme == nil -> false
      String.downcase(parsed.scheme) in ["javascript", "data", "vbscript", "file"] -> false
      https_or_loopback?(parsed) -> true
      application_type == "native" -> parsed.scheme not in ["http", "https"]
      true -> false
    end
  end

  defp https_or_loopback?(%URI{scheme: "https", host: host}) when host not in [nil, ""], do: true

  defp https_or_loopback?(%URI{scheme: "http", host: host})
       when host in ["localhost" | @loopback_hosts], do: true

  defp https_or_loopback?(_uri), do: false

  defp invalid(description), do: {:error, "invalid_client_metadata", description}

  @doc "A registration error as an `Authmk.Error`, for the non-OAuth endpoints."
  def error("invalid_redirect_uri", description),
    do: Authmk.Error.custom(:invalid_redirect_uri, 400, description)

  def error(_metadata_error, description),
    do: Authmk.Error.custom(:invalid_client_metadata, 400, description)
end
