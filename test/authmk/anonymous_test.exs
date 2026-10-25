defmodule Authmk.AnonymousTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Test.{Browser, FakeProvider, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Anonymous, on_link_account: &__MODULE__.on_link_account/2}
      ],
      social_providers: [github: [client_id: "github-id", client_secret: "client-secret"]],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]

    def on_link_account(%{anonymous_user: anonymous, new_user: user}, _ctx),
      do: send(self(), {:linked, anonymous.id, user.email})
  end

  @moduletag auth: Auth

  defp sign_in_anonymously(browser) do
    {browser, conn} = post(browser, "/sign-in/anonymous")
    {browser, json(conn)["user"]}
  end

  defp emails, do: Repo.all(from(u in "users", select: u.email))

  test "signs in a generated user", %{browser: browser} do
    {browser, user} = sign_in_anonymously(browser)

    assert user["is_anonymous"] == true
    assert user["name"] == "Anonymous"
    assert user["email"] =~ ~r/^temp-[0-9a-f]{20}@localhost$/

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["id"] == user["id"]
  end

  test "anonymous users can't sign in anonymously again", %{browser: browser} do
    {browser, _user} = sign_in_anonymously(browser)
    {_browser, conn} = post(browser, "/sign-in/anonymous")
    assert json(conn)["error"]["code"] == "already_anonymous"
    assert Repo.aggregate("users", :count) == 1
  end

  test "signing up links the accounts and deletes the anonymous user", %{browser: browser} do
    {browser, anonymous} = sign_in_anonymously(browser)
    {browser, _user} = sign_up(browser)

    assert_received {:linked, id, "ada@example.com"}
    assert to_string(id) == anonymous["id"]
    assert emails() == ["ada@example.com"]

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"
  end

  test "so does social sign-in", %{browser: browser} do
    FakeProvider.stub(Auth,
      profile: %{"id" => 1, "login" => "ada", "name" => "Ada", "email" => "ada@example.com"},
      emails: [%{"email" => "ada@example.com", "primary" => true, "verified" => true}]
    )

    {browser, anonymous} = sign_in_anonymously(browser)

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "github", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/github", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) == "/done"

    assert_received {:linked, id, "ada@example.com"}
    assert to_string(id) == anonymous["id"]
    assert Repo.aggregate("users", :count) == 1
  end

  test "a failed sign-in links nothing", %{browser: browser} do
    {_other, _user} = sign_up(Browser.new(Auth))
    {browser, _anonymous} = sign_in_anonymously(browser)

    {_browser, conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "wrong password"})

    assert conn.status == 401
    refute_received {:linked, _id, _email}
    assert Repo.aggregate("users", :count) == 2
  end

  test "signing in without an anonymous session links nothing", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, _conn} = post(browser, "/sign-out")

    {_browser, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    refute_received {:linked, _id, _email}
  end
end

defmodule Authmk.AnonymousOptionsTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Repo

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Anonymous,
         email_domain: "guests.example.com",
         generate_name: &__MODULE__.name/0,
         disable_delete_anonymous_user: true}
      ]

    def name, do: "Guest"
  end

  defmodule GeneratedEmailAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [{Authmk.Plugins.Anonymous, generate_email: &__MODULE__.email/0}]

    def email, do: "guest-#{System.unique_integer([:positive])}@example.org"
  end

  @moduletag auth: Auth

  test "custom domain and name; the anonymous user stays after linking", %{browser: browser} do
    {browser, conn} = post(browser, "/sign-in/anonymous")
    assert json(conn)["user"]["name"] == "Guest"
    assert json(conn)["user"]["email"] =~ "@guests.example.com"

    {_browser, _user} = sign_up(browser)
    assert Repo.aggregate("users", :count) == 2
  end

  @tag auth: GeneratedEmailAuth
  test "generated emails", %{browser: browser} do
    {_browser, conn} = post(browser, "/sign-in/anonymous")
    assert json(conn)["user"]["email"] =~ ~r/^guest-\d+@example\.org$/
  end
end
