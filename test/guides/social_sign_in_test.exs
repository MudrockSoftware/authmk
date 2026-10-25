defmodule MyApp.Auth.GitHubOrg do
  # The provider from guides/social-sign-in.md, verbatim. Keep them in sync.
  use Authmk.OAuth.Provider

  alias Authmk.OAuth.Provider
  alias Authmk.OAuth.Providers.GitHub

  @impl true
  defdelegate config, to: GitHub

  @impl true
  defdelegate map_profile(profile, tokens), to: GitHub

  @impl true
  def user_info(tokens, provider, ctx) do
    with {:ok, profile} <- GitHub.user_info(tokens, provider, ctx),
         {:ok, _membership} <-
           Provider.get_json(
             ctx,
             "https://api.github.com/user/memberships/orgs/acme",
             tokens.access_token
           ) do
      {:ok, profile}
    end
  end
end

defmodule Authmk.Guides.SocialSignInTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{FakeProvider, ProviderCase, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [
        github: [
          provider: MyApp.Auth.GitHubOrg,
          client_id: "client-id",
          client_secret: "client-secret"
        ]
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]

    # The callback from the guide, verbatim.
    @impl Authmk
    def map_social_profile(
          %{provider: :github, user: %{email: nil} = user, profile: profile},
          _ctx
        ),
        do: {:ok, %{user | email: "#{profile["id"]}@users.noreply.example.com"}}

    def map_social_profile(%{user: %{email: email} = user}, _ctx) do
      if String.ends_with?(email, "@example.com"),
        do: {:ok, user},
        else: {:error, Authmk.Error.custom(:not_an_employee, 403, "Employees only")}
    end
  end

  @moduletag auth: Auth

  @profile %{"id" => 42, "login" => "ada", "name" => "Ada", "email" => "ada@example.com"}
  @membership %{"/user/memberships/orgs/acme" => %{"state" => "active"}}

  defp start(browser, fake) do
    FakeProvider.stub(Auth, fake)

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "github", callback_url: "/done"})

    get(browser, "/callback/github", FakeProvider.approve(json(conn)["url"]))
  end

  test "members of the organization sign in", %{browser: browser} do
    %{user: user} =
      ProviderCase.sign_in_through(browser, Auth, :github, profile: @profile, routes: @membership)

    assert user["email"] == "ada@example.com"
  end

  test "others don't", %{browser: browser} do
    {_browser, conn} = start(browser, profile: @profile)
    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
  end

  test "users without an email get a placeholder", %{browser: browser} do
    {_browser, conn} = start(browser, profile: %{@profile | "email" => nil}, routes: @membership)

    assert redirected_to(conn) == "/done"
    assert Repo.all(from(u in "users", select: u.email)) == ["42@users.noreply.example.com"]
  end

  test "only employees", %{browser: browser} do
    {_browser, conn} =
      start(browser,
        profile: %{@profile | "email" => "eve@elsewhere.example"},
        routes: @membership
      )

    assert redirected_to(conn) =~ "error=not_an_employee"
  end
end
