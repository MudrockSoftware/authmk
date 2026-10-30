defmodule Authmk.Test.FakeProvider do
  @moduledoc false
  # Stands in for OAuth providers over Req.Test, so social sign-in runs end
  # to end without the network.
  #
  # Authorization codes are "code:" <> the PKCE challenge, so the token
  # endpoint checks the code verifier like a real provider would.
  #
  # Options:
  #
  #   * `routes:` - GET API paths (bearer token required) => answer.
  #     GitHub's `/user` and `/user/emails` come from `profile:`/`emails:`.
  #   * `post_routes:` - POST API paths (bearer token required) => answer.
  #     Every other POST is a token request.
  #   * `public_routes:` - GET paths answered without a bearer token.
  #   * `jwks:` served at `jwks_path:` (Google's by default), without a token.
  #   * `id_token:`, `expires_in:`, `refresh_token:`, `scope:`, `access_token:` -
  #     token response fields.
  #   * `redirect_uri:` - the callback the code was issued for: code exchanges
  #     must send it, as real providers require.
  #   * `client_secret:` (default "client-secret"); `token_auth: :basic | :post`
  #     accepts only that client authentication; `public_client: true` none.
  #
  # A path ending in `*` matches every path it prefixes.
  #
  # An answer is JSON, `{:raw, content_type, body}`, or a function of the
  # conn (query params fetched). A function in `routes:` answers any method
  # to its path, without the bearer check, for requests that are neither
  # API GETs nor standard token POSTs. A function returns a JSON body (200)
  # or `{status, json_or_text}`.

  import Plug.Conn

  @doc "Routes the auth module's outbound requests (Req.Test `name`) to a fake provider."
  def stub(name, opts \\ []) do
    Req.Test.stub(name, &handle(&1, opts))
  end

  @doc """
  Plays the provider's authorization page: approves the request in `url`
  and returns the callback params.
  """
  def approve(url) do
    query = URI.decode_query(URI.parse(url).query)
    %{"code" => "code:" <> (query["code_challenge"] || "no-pkce"), "state" => query["state"]}
  end

  @doc "A fresh signing key (`:rsa` for RS256, `:ec` for ES256) and its public JWKS."
  def signing_key(type \\ :rsa) do
    jwk = JOSE.JWK.generate_key(if type == :ec, do: {:ec, "P-256"}, else: {:rsa, 2048})
    {_kty, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    {jwk,
     %{"keys" => [Map.merge(public, %{"kid" => kid(jwk), "alg" => alg(jwk), "use" => "sig"})]}}
  end

  @doc """
  Fake options for a token response with an ID token signed by a fresh key,
  and that key served as the provider's JWKS at `jwks_path`.
  """
  def signed_id_token(claims, jwks_path) do
    {jwk, jwks} = signing_key()
    [id_token: id_token(jwk, claims), jwks: jwks, jwks_path: jwks_path]
  end

  @doc "Signs ID token claims with `jwk`, like a provider."
  def id_token(jwk, claims, header \\ nil) do
    header = header || %{"alg" => alg(jwk), "kid" => kid(jwk)}
    {_alg, token} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    token
  end

  # Each key has its own id, like a provider's keys after rotation.
  defp kid(jwk), do: JOSE.JWK.thumbprint(jwk)

  defp alg(jwk) do
    case JOSE.JWK.to_map(jwk) do
      {_kty, %{"kty" => "EC"}} -> "ES256"
      {_kty, %{"kty" => "oct"}} -> "HS256"
      _rsa -> "RS256"
    end
  end

  defp handle(conn, opts) do
    routes = routes(opts)
    conn = %{conn | request_path: route_key(routes, public_routes(opts), conn.request_path)}

    case routes[conn.request_path] do
      route when is_function(route, 1) -> answer(conn, route)
      _not_a_function -> dispatch(conn, routes, opts)
    end
  end

  defp dispatch(conn, routes, opts) do
    public_routes = public_routes(opts)
    post_routes = opts[:post_routes] || %{}

    case {conn.method, conn.request_path} do
      {"POST", path} when is_map_key(post_routes, path) -> authorized(conn, post_routes[path])
      {"POST", _token_path} -> token(conn, opts)
      {"GET", path} when is_map_key(public_routes, path) -> answer(conn, public_routes[path])
      {"GET", path} when is_map_key(routes, path) -> authorized(conn, routes[path])
      _other -> json(conn, 404, %{"error" => "not_found", "path" => conn.request_path})
    end
  end

  # The route a path takes: its own, or a `*` route that prefixes it.
  defp route_key(routes, public_routes, path) do
    keys = Map.keys(routes) ++ Map.keys(public_routes)

    if path in keys,
      do: path,
      else:
        Enum.find(keys, path, fn key ->
          String.ends_with?(key, "*") and
            String.starts_with?(path, String.trim_trailing(key, "*"))
        end)
  end

  defp routes(opts) do
    Map.merge(
      %{"/user" => opts[:profile], "/user/emails" => opts[:emails] || []},
      opts[:routes] || %{}
    )
  end

  # JWKS documents are public: no bearer token.
  defp public_routes(opts) do
    jwks_path = opts[:jwks_path] || "/oauth2/v3/certs"
    Map.merge(%{jwks_path => opts[:jwks] || %{"keys" => []}}, opts[:public_routes] || %{})
  end

  defp token(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body)

    cond do
      not client_authenticated?(conn, form, opts) ->
        json(conn, 401, %{"error" => "invalid_client"})

      form["grant_type"] == "refresh_token" ->
        json(conn, 200, tokens(opts, "refreshed"))

      opts[:redirect_uri] && form["redirect_uri"] != opts[:redirect_uri] ->
        json(conn, 400, %{"error" => "invalid_grant"})

      valid_code?(form) ->
        json(conn, 200, tokens(opts, "access"))

      true ->
        json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  # The secret in the form, or in HTTP Basic auth. With `token_auth: :basic`
  # or `token_auth: :post` in `opts`, only that method is accepted.
  defp client_authenticated?(conn, form, opts) do
    secret = opts[:client_secret] || "client-secret"

    case get_req_header(conn, "authorization") do
      ["Basic " <> credentials] ->
        opts[:token_auth] != :post and basic_secret?(credentials, secret)

      _no_basic ->
        opts[:token_auth] != :basic and
          (form["client_secret"] == secret or opts[:public_client] == true)
    end
  end

  defp basic_secret?(credentials, secret) do
    case Base.decode64(credentials) do
      {:ok, decoded} -> String.ends_with?(decoded, ":" <> secret)
      :error -> false
    end
  end

  defp valid_code?(%{"code" => "code:" <> challenge, "code_verifier" => verifier}) do
    challenge == :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
  end

  # Providers without PKCE send no verifier; the code alone is enough then.
  defp valid_code?(%{"code" => "code:" <> _challenge} = form),
    do: not Map.has_key?(form, "code_verifier")

  defp valid_code?(_form), do: false

  defp tokens(opts, prefix) do
    %{
      "access_token" => opts[:access_token] || "#{prefix}-#{System.unique_integer([:positive])}",
      "refresh_token" => opts[:refresh_token] || "refresh-token",
      "expires_in" => Keyword.get(opts, :expires_in, 3600),
      "scope" => opts[:scope] || "read:user user:email",
      "token_type" => "bearer",
      "id_token" => opts[:id_token]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp authorized(conn, answer) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token] -> answer(conn, answer)
      _ -> json(conn, 401, %{"message" => "Requires authentication"})
    end
  end

  defp answer(conn, route) when is_function(route, 1) do
    case conn |> fetch_query_params() |> route.() do
      {status, text} when is_integer(status) and is_binary(text) ->
        conn |> put_resp_content_type("text/plain") |> send_resp(status, text)

      {status, body} when is_integer(status) ->
        json(conn, status, body)

      body ->
        json(conn, 200, body)
    end
  end

  defp answer(conn, {:raw, content_type, body}) do
    conn |> put_resp_content_type(content_type, nil) |> send_resp(200, body)
  end

  defp answer(conn, body), do: json(conn, 200, body)

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end
end
