defmodule Authmk.Providers.GitLabTest do
  use Authmk.Test.ProviderCase, provider: :gitlab

  alias Authmk.Test.{FakeProvider, Repo}

  defp profile(overrides) do
    Map.merge(
      %{
        "id" => 42,
        "username" => "ada",
        "name" => "Ada Lovelace",
        "email" => "ada@example.com",
        "avatar_url" => "https://gitlab.com/uploads/ada.png",
        "state" => "active",
        "locked" => false
      },
      overrides
    )
  end

  defp sign_in_with(browser, profile), do: sign_in(browser, routes: %{"/api/v4/user" => profile})

  # Runs the flow up to the callback and returns where it redirected.
  defp callback_location(browser, auth, profile) do
    FakeProvider.stub(auth, routes: %{"/api/v4/user" => profile})

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "gitlab", callback_url: "/done"})

    url = json(conn)["url"]
    {_browser, conn} = get(browser, "/callback/gitlab", FakeProvider.approve(url))
    redirected_to(conn)
  end

  test "signs in with PKCE", %{browser: browser} do
    %{url: url, user: user} = sign_in_with(browser, profile(%{"email_verified" => true}))

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "gitlab.com/oauth/authorize"
    assert query["scope"] == "read_user"
    assert query["code_challenge_method"] == "S256"

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://gitlab.com/uploads/ada.png"
  end

  test "the email is unverified unless GitLab says so, and the username stands in for the name",
       %{browser: browser} do
    %{user: user} = sign_in_with(browser, profile(%{"name" => nil}))
    assert user["email_verified"] == false
    assert user["name"] == "ada"
  end

  test "blocked and locked users can't sign in", %{browser: browser, auth: auth} do
    for overrides <- [%{"state" => "blocked"}, %{"locked" => true}] do
      location = callback_location(browser, auth, profile(overrides))
      assert location =~ "error=unable_to_get_user_info"
    end

    assert Repo.aggregate("users", :count) == 0
  end
end

defmodule Authmk.Providers.GitLabSelfManagedTest do
  use Authmk.EmulationCase, async: true

  import Authmk.Test.ProviderCase

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [
        gitlab: [
          client_id: "client-id",
          client_secret: "client-secret",
          instance_url: "https://gitlab.example.com/"
        ]
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  test "a self-managed instance works through instance_url", %{browser: browser} do
    profile = %{
      "id" => 7,
      "username" => "grace",
      "email" => "grace@example.com",
      "state" => "active"
    }

    %{url: url, user: user} =
      sign_in_through(browser, Auth, :gitlab, routes: %{"/api/v4/user" => profile})

    assert url =~ "https://gitlab.example.com/oauth/authorize?"
    assert user["email"] == "grace@example.com"
  end
end
