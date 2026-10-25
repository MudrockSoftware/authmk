defmodule Authmk.SocialHooksTest do
  # The app's say in social sign-in: extra data through the flow, mapping
  # and refusing provider users, and providers that must verify emails.
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{FakeProvider, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [
        github: [client_id: "github-id", client_secret: "client-secret"],
        strict_github: [
          provider: Authmk.OAuth.Providers.GitHub,
          client_id: "github-id",
          client_secret: "client-secret",
          require_email_verification: true
        ]
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]

    # GitHub users without a public email get a placeholder; "mallory" may
    # not sign in at all.
    @impl Authmk
    def map_social_profile(%{profile: %{"login" => "mallory"}}, _ctx),
      do: {:error, Authmk.Error.custom(:user_banned, 403, "Banned")}

    def map_social_profile(%{user: %{email: nil} = user, profile: profile}, _ctx),
      do: {:ok, %{user | email: "#{profile["login"]}@users.noreply.example"}}

    def map_social_profile(%{user: user}, _ctx), do: {:ok, user}

    @impl Authmk
    def database_hook(:before_create, :user, attrs, ctx) do
      case ctx.private[:oauth_additional_data] do
        %{"referrer" => referrer} -> send(self(), {:referrer, referrer})
        _none -> :ok
      end

      {:ok, attrs}
    end

    def database_hook(_event, _model, data, _ctx), do: {:ok, data}
  end

  @moduletag auth: Auth

  @profile %{"id" => 42, "login" => "ada", "name" => "Ada", "email" => nil}
  @emails [%{"email" => "ada@example.com", "primary" => true, "verified" => true}]

  defp sign_in(browser, fake, params \\ %{}) do
    FakeProvider.stub(Auth, fake)

    {browser, conn} =
      post(
        browser,
        "/sign-in/social",
        Map.merge(%{provider: "github", callback_url: "/done"}, params)
      )

    case json(conn) do
      %{"url" => url} ->
        provider = params[:provider] || "github"
        get(browser, "/callback/#{provider}", FakeProvider.approve(url))

      _error ->
        {browser, conn}
    end
  end

  test "additional data comes back to the app after the provider", %{browser: browser} do
    {_browser, conn} =
      sign_in(browser, [profile: @profile, emails: @emails], %{
        additional_data: %{referrer: "newsletter"}
      })

    assert redirected_to(conn) == "/done"
    assert_received {:referrer, "newsletter"}
  end

  test "additional data must stay small", %{browser: browser} do
    {_browser, conn} =
      sign_in(browser, [profile: @profile, emails: @emails], %{
        additional_data: %{blob: String.duplicate("x", 2000)}
      })

    assert json(conn)["error"]["code"] == "validation_failed"
  end

  test "the app fills in an email the provider didn't share", %{browser: browser} do
    {_browser, conn} = sign_in(browser, profile: @profile, emails: [])
    assert redirected_to(conn) == "/done"

    assert Repo.all(from(u in "users", select: u.email)) == ["ada@users.noreply.example"]
  end

  test "the app refuses a provider user", %{browser: browser} do
    {_browser, conn} =
      sign_in(browser, profile: %{@profile | "login" => "mallory"}, emails: @emails)

    assert redirected_to(conn) =~ "error=user_banned"
    assert Repo.aggregate("users", :count) == 0
  end

  test "require_email_verification refuses unverified provider emails", %{browser: browser} do
    unverified = [%{"email" => "ada@example.com", "primary" => true, "verified" => false}]

    {_browser, conn} =
      sign_in(browser, [profile: @profile, emails: unverified], %{provider: "strict_github"})

    assert redirected_to(conn) =~ "error=email_not_verified"

    {_browser, conn} =
      sign_in(browser, [profile: @profile, emails: @emails], %{provider: "strict_github"})

    assert redirected_to(conn) == "/done"
  end

  test "scopes granted earlier are kept when signing in again", %{browser: browser} do
    {browser, _conn} = sign_in(browser, profile: @profile, emails: @emails)

    {_browser, conn} =
      sign_in(browser, [profile: @profile, emails: @emails, scope: "repo"], %{scopes: ["repo"]})

    assert redirected_to(conn) == "/done"
    [scope] = Repo.all(from(a in "accounts", select: a.scope))
    assert scope == "read:user,user:email,repo"
  end
end
