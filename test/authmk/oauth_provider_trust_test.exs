defmodule Authmk.OAuthProviderTrustTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plugins.OAuthProvider
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.JWT,
        {Authmk.Plugins.OAuthProvider,
         login_page: "/sign-in",
         consent_page: "/consent",
         trusted_clients: ["first-party-app"],
         client_reference: &__MODULE__.team/1,
         reference_access: &__MODULE__.member?/3,
         validate_redirect_uri: &__MODULE__.redirect_uri?/3}
      ]

    # A team per email domain, standing in for organizations.
    def team(%{user: %{email: email}}), do: email |> String.split("@") |> List.last()
    def member?(user, team, _ctx), do: String.ends_with?(user.email, "@" <> team)

    # Preview deployments of a registered app: any pr-N subdomain.
    def redirect_uri?(uri, _registered, default),
      do: default or Regex.match?(~r{\Ahttps://pr-\d+\.app\.example/cb\z}, uri)
  end

  @moduletag auth: Auth

  @redirect_uri "https://app.example/cb"

  defp authorize(browser, client_id) do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    {browser, conn} =
      get(browser, "/oauth2/authorize", %{
        response_type: "code",
        client_id: client_id,
        redirect_uri: @redirect_uri,
        scope: "openid",
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    {browser, redirected_to(conn)}
  end

  test "trusted clients skip consent, from a short-lived cache", %{browser: browser} do
    {:ok, client} =
      OAuthProvider.create_client(Auth, %{"redirect_uris" => [@redirect_uri]},
        client_id: "first-party-app"
      )

    assert client.client_id == "first-party-app"
    {browser, _user} = sign_up(browser)
    {browser, location} = authorize(browser, "first-party-app")
    assert "https://app.example/cb?code=" <> _ = location

    # Read from the cache now: a change made behind authmk's back waits
    # for it to expire. Changes through authmk drop it at once.
    Repo.update_all(from(c in "oauth_clients"), set: [disabled: true])
    {_browser, location} = authorize(browser, "first-party-app")
    assert "https://app.example/cb?code=" <> _ = location

    assert {:error, %{code: :invalid_client_metadata}} =
             OAuthProvider.create_client(Auth, %{"redirect_uris" => [@redirect_uri]},
               client_id: "short"
             )
  end

  test "the app decides which redirect URIs count", %{browser: browser} do
    {:ok, client} =
      OAuthProvider.create_client(Auth, %{"redirect_uris" => [@redirect_uri]}, skip_consent: true)

    {browser, _user} = sign_up(browser)

    preview = fn uri ->
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

      {_browser, conn} =
        get(browser, "/oauth2/authorize", %{
          response_type: "code",
          client_id: client.client_id,
          redirect_uri: uri,
          scope: "openid",
          code_challenge: challenge,
          code_challenge_method: "S256"
        })

      redirected_to(conn)
    end

    assert "https://pr-42.app.example/cb?code=" <> _ = preview.("https://pr-42.app.example/cb")
    assert preview.("https://evil.example/cb") =~ "http://localhost:4000/auth/error"
  end

  test "an organization's clients: shared by its members, and for them only", %{browser: browser} do
    {browser, _user} = sign_up(browser, %{email: "ada@acme.example"})

    {browser, conn} =
      post(browser, "/oauth2/create-client", %{"redirect_uris" => [@redirect_uri]})

    client_id = json(conn)["client_id"]

    # A teammate manages it too; an outsider doesn't see it.
    {teammate, _user} = sign_up(Browser.new(Auth), %{email: "bob@acme.example"})
    {teammate, conn} = get(teammate, "/oauth2/get-clients")
    assert [%{"client_id" => ^client_id}] = json(conn)

    {outsider, _user} = sign_up(Browser.new(Auth), %{email: "eve@other.example"})
    {outsider, conn} = get(outsider, "/oauth2/get-client", %{client_id: client_id})
    assert conn.status == 404

    # Members can sign in to it (after consent); others are turned away.
    {_teammate, location} = authorize(teammate, client_id)
    assert "http://localhost:4000/consent?" <> _ = location

    {_outsider, location} = authorize(outsider, client_id)
    assert URI.decode_query(URI.parse(location).query)["error"] == "access_denied"

    # Deleting it through authmk works for the team.
    {_browser, conn} = post(browser, "/oauth2/delete-client", %{client_id: client_id})
    assert json(conn) == %{"success" => true}
  end
end
