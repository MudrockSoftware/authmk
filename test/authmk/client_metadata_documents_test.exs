defmodule Authmk.ClientMetadataDocumentsTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         client_id_metadata_documents: true,
         resolve_host: &__MODULE__.resolve/1}
      ]

    # A stand-in for DNS: some hosts sit on private networks.
    @private %{
      "internal.example" => {10, 0, 0, 7},
      "loopback.example" => {0, 0, 0, 0, 0, 0, 0, 1},
      "link-local.example" => {169, 254, 169, 254},
      "lan.example" => {192, 168, 1, 1},
      "docker.example" => {172, 17, 0, 1},
      "cgnat.example" => {100, 64, 0, 1},
      "unique-local.example" => {0xFD00, 0, 0, 0, 0, 0, 0, 1},
      "v6-link-local.example" => {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      "mapped.example" => {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
    }

    def private_hosts, do: Map.keys(@private)
    def resolve("nowhere.example"), do: :error
    def resolve(host), do: {:ok, [Map.get(@private, host, {93, 184, 216, 34})]}
  end

  @moduletag auth: Auth

  @client_id "https://client.example/oauth/client.json"
  @redirect_uri "https://client.example/callback"

  defp document(overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => @client_id,
        "client_name" => "Client Example",
        "redirect_uris" => [@redirect_uri]
      },
      overrides
    )
  end

  # The client's web server; counts the fetches.
  defp serve(answer) do
    test = self()

    Req.Test.stub(Auth, fn conn ->
      send(test, {:fetched, conn.host <> conn.request_path})
      respond(conn, answer)
    end)
  end

  defp respond(conn, {:json, document, headers}) do
    headers
    |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)
    |> Req.Test.json(document)
  end

  defp respond(conn, {status, body}), do: Plug.Conn.send_resp(conn, status, body)

  defp authorize(browser, client_id, redirect_uri \\ @redirect_uri) do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    {browser, conn} =
      get(browser, "/oauth2/authorize", %{
        response_type: "code",
        client_id: client_id,
        redirect_uri: redirect_uri,
        scope: "openid",
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    {browser, redirected_to(conn), verifier}
  end

  defp known?(location), do: not String.contains?(location, "error=invalid_client")

  test "a client is its URL: fetched, then used like any other", %{browser: browser} do
    serve({:json, document(), [{"cache-control", "max-age=600"}]})
    {browser, _user} = sign_up(browser)

    {browser, consent_page, verifier} = authorize(browser, @client_id)
    assert "http://localhost:4000/consent?" <> _ = consent_page
    assert_received {:fetched, "client.example/oauth/client.json"}

    oauth_query = URI.decode_query(URI.parse(consent_page).query)["oauth_query"]
    {browser, conn} = post(browser, "/oauth2/consent", %{oauth_query: oauth_query, accept: true})
    code = URI.decode_query(URI.parse(json(conn)["url"]).query)["code"]

    {_client, conn} =
      post(%{Browser.new(Auth) | origin: nil}, "/oauth2/token", %{
        grant_type: "authorization_code",
        client_id: @client_id,
        code: code,
        redirect_uri: @redirect_uri,
        code_verifier: verifier
      })

    assert json(conn)["access_token"]
    # Kept for its max-age: no second fetch.
    refute_received {:fetched, _}

    {_browser, conn} = get(browser, "/.well-known/oauth-authorization-server")
    assert json(conn)["client_id_metadata_document_supported"] == true
  end

  test "when it expires, the document is fetched again, and fails closed", %{browser: browser} do
    serve({:json, document(), []})
    {browser, _user} = sign_up(browser)
    {browser, location, _verifier} = authorize(browser, @client_id)
    assert known?(location)

    # The document changed: a new redirect URI.
    Repo.update_all("oauth_clients",
      set: [metadata_document_expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    serve({:json, document(%{"redirect_uris" => ["https://client.example/new"]}), []})
    {browser, location, _verifier} = authorize(browser, @client_id, "https://client.example/new")
    assert known?(location)

    # Gone from the web: no longer trusted.
    Repo.update_all("oauth_clients",
      set: [metadata_document_expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    serve({404, "not found"})
    {_browser, location, _verifier} = authorize(browser, @client_id, "https://client.example/new")
    refute known?(location)
  end

  test "documents and URLs that don't follow the rules are refused", %{browser: browser} do
    for {client_id, answer} <- [
          {@client_id,
           {:json, document(%{"client_id" => "https://client.example/other.json"}), []}},
          {@client_id,
           {:json, document(%{"token_endpoint_auth_method" => "client_secret_post"}), []}},
          {@client_id, {:json, document(%{"client_secret" => "shh"}), []}},
          {@client_id, {:json, document(%{"redirect_uris" => ["javascript:alert(1)"]}), []}},
          {@client_id, {200, String.duplicate("x", 6_000)}},
          {@client_id, {302, ""}},
          {@client_id, {200, "not json"}},
          {"https://internal.example/client.json",
           {:json, document(%{"client_id" => "https://internal.example/client.json"}), []}},
          {"https://loopback.example/client.json",
           {:json, document(%{"client_id" => "https://loopback.example/client.json"}), []}},
          {"http://client.example/client.json",
           {:json, document(%{"client_id" => "http://client.example/client.json"}), []}},
          {"https://client.example/",
           {:json, document(%{"client_id" => "https://client.example/"}), []}},
          {"https://client.example/a/../client.json",
           {:json, document(%{"client_id" => "https://client.example/a/../client.json"}), []}},
          {"https://client.example/client.json?x=1",
           {:json, document(%{"client_id" => "https://client.example/client.json?x=1"}), []}}
        ] do
      serve(answer)
      {_browser, location, _verifier} = authorize(browser, client_id)
      refute known?(location), inspect({client_id, answer})
    end

    for host <- ["nowhere.example" | Auth.private_hosts()] do
      client_id = "https://#{host}/client.json"
      serve({:json, document(%{"client_id" => client_id}), []})
      {_browser, location, _verifier} = authorize(browser, client_id)
      refute known?(location), host
    end

    # Private networks aren't even asked.
    serve({:json, document(), []})
    {_browser, _location, _verifier} = authorize(browser, "https://internal.example/client.json")
    refute_received {:fetched, "internal.example" <> _}
  end
end
