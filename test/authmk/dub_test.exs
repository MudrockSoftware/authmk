defmodule Authmk.DubTest do
  # Dub: sign-ups from Dub links become leads; sales are reported; Dub
  # accounts are linked to users (Dub gives no email), then sign them in.
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.Dub
  alias Authmk.Test.{Browser, FakeProvider, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [dub: [client_id: "dub-client", client_secret: "client-secret"]],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.Dub, api_key: "dub_key"}]
  end

  @moduletag auth: Auth

  # Dub: its tracking API, and its OAuth server with this user.
  setup do
    test = self()

    tracker = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:dub, conn.request_path, JSON.decode!(body),
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      %{"ok" => true}
    end

    FakeProvider.stub(Auth,
      routes: %{
        "/track/lead" => tracker,
        "/track/sale" => tracker,
        "/oauth/userinfo" => %{
          "id" => "dub_user_1",
          "name" => "Ada at Dub",
          "image" => "https://dub.co/ada.png"
        }
      }
    )

    :ok
  end

  test "a sign-up from a Dub link is a lead; others aren't", %{browser: browser} do
    from_link = %{browser | cookies: Map.put(browser.cookies, "dub_id", "click_123")}
    {_browser, user} = sign_up(from_link)

    assert_received {:dub, "/track/lead", lead, ["Bearer dub_key"]}

    assert lead == %{
             "clickId" => "click_123",
             "eventName" => "Sign Up",
             "customerExternalId" => user["id"],
             "customerName" => "Ada",
             "customerEmail" => "ada@example.com"
           }

    {_browser, _user} = sign_up(Browser.new(Auth), %{email: "grace@example.com"})
    refute_received {:dub, "/track/lead", _lead, _auth}
  end

  test "sales, from the app's code", %{browser: browser} do
    {_browser, user} = sign_up(browser)
    assert :ok = Dub.track_sale(Auth, user["id"], 4900, invoice_id: "in_1")

    assert_received {:dub, "/track/sale",
                     %{
                       "customerExternalId" => id,
                       "amount" => 4900,
                       "currency" => "usd",
                       "invoiceId" => "in_1"
                     }, _auth}

    assert id == user["id"]
  end

  test "a Dub account is linked, then signs its user in; unlinked ones create nobody", %{
    browser: browser
  } do
    {browser, _user} = sign_up(browser)
    {browser, conn} = post(browser, "/link-social", %{provider: "dub", callback_url: "/settings"})
    url = json(conn)["url"]
    assert url =~ "https://app.dub.co/oauth/authorize?"
    assert URI.decode_query(URI.parse(url).query)["code_challenge_method"] == "S256"

    {_browser, conn} = get(browser, "/callback/dub", FakeProvider.approve(url))
    assert redirected_to(conn) == "/settings"

    # Signing in with Dub now: that user.
    {visitor, conn} =
      post(Browser.new(Auth), "/sign-in/social", %{provider: "dub", callback_url: "/home"})

    {visitor, conn} = get(visitor, "/callback/dub", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) == "/home"
    {_visitor, conn} = get(visitor, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"

    # Another Dub account, linked to nobody: no user made without an email.
    FakeProvider.stub(Auth,
      routes: %{"/oauth/userinfo" => %{"id" => "dub_user_2", "name" => "Eve"}}
    )

    {stranger, conn} =
      post(Browser.new(Auth), "/sign-in/social", %{provider: "dub", callback_url: "/home"})

    {_stranger, conn} = get(stranger, "/callback/dub", FakeProvider.approve(json(conn)["url"]))
    assert redirected_to(conn) =~ "error=email_not_found"
    assert Repo.aggregate("users", :count) == 1
  end
end
