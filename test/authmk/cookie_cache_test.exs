defmodule Authmk.CookieCacheTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    schema: [session: [additional_fields: [theme: [type: :string]]]],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    session: [cookie_cache: [enabled: true, max_age: 60]],
    cookies: [session_data: [name: "app_session_cache"]]

  @impl Authmk
  def customize_session(%{user: user} = session, _ctx),
    do: Map.put(session, :greeting, "Hi #{user.name}")
end

defmodule Authmk.CookieCacheTest.EncryptedAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    session: [cookie_cache: [enabled: true, strategy: :encrypted]]
end

defmodule Authmk.CookieCacheTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.CookieCacheTest.Auth
  alias Authmk.Crypto
  alias Authmk.Plug.FetchSession
  alias Authmk.Test.Repo

  @moduletag auth: Auth

  test "get-session reads from the cache without the database", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    assert cookie(browser, "app_session_cache")

    # The database no longer knows the session, but the cache is still fresh.
    Repo.delete_all("sessions")
    {browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"

    # Asking for a fresh read goes to the database, which signs the browser out.
    {_browser, conn} = get(browser, "/get-session", %{disable_cookie_cache: true})
    assert json(conn) == nil
  end

  test "endpoints that change things never trust the cache", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    Repo.delete_all("sessions")

    {_browser, conn} = post(browser, "/update-user", %{name: "Mallory"})
    assert json(conn)["error"]["code"] == "unauthorized"
  end

  test "an expired cache falls back to the database", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    Repo.update_all("users", set: [name: "Ada Updated"])

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["name"] == "Ada"

    expired = rewrite_cache(browser, fn payload -> %{payload | "expires_at" => 0} end)
    {_browser, conn} = get(expired, "/get-session")
    assert json(conn)["user"]["name"] == "Ada Updated"
  end

  test "update-user refreshes the cache", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {browser, _conn} = post(browser, "/update-user", %{name: "Ada L."})

    Repo.delete_all("sessions")
    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["name"] == "Ada L."
  end

  test "a tampered or moved cache is ignored", %{browser: browser} do
    {ada, _user} = sign_up(browser)
    {bob, _user} = sign_up(browser, %{email: "bob@example.com"})

    tampered = %{ada | cookies: Map.update!(ada.cookies, "app_session_cache", &(&1 <> "x"))}
    {_browser, conn} = get(tampered, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"

    # Bob's token with Ada's cache: the cache is bound to Ada's token.
    swapped = %{
      bob
      | cookies: Map.put(bob.cookies, "app_session_cache", cookie(ada, "app_session_cache"))
    }

    {_browser, conn} = get(swapped, "/get-session")
    assert json(conn)["user"]["email"] == "bob@example.com"
  end

  test "update-session changes extra session fields only", %{browser: browser} do
    {browser, _user} = sign_up(browser)

    {browser, conn} =
      post(browser, "/update-session", %{theme: "dark", expires_at: "2099-01-01T00:00:00Z"})

    assert json(conn)["session"]["theme"] == "dark"
    {_browser, conn} = get(browser, "/get-session", %{disable_cookie_cache: true})
    refute json(conn)["session"]["expires_at"] =~ "2099"
  end

  test "customize_session shapes the response", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["greeting"] == "Hi Ada"
  end

  test "Authmk.Plug.FetchSession reads from the cache", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    Repo.delete_all("sessions")

    conn =
      Enum.reduce(browser.cookies, Plug.Test.conn(:get, "/"), fn {name, value}, conn ->
        Plug.Test.put_req_cookie(conn, name, value)
      end)
      |> FetchSession.call(Auth)

    assert conn.assigns.current_user.email == "ada@example.com"
  end

  describe "encrypted strategy" do
    @describetag auth: Authmk.CookieCacheTest.EncryptedAuth

    test "the cache can't be read by the browser", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      cache = cookie(browser, "authmk.session_data")

      refute cache =~ "ada@example.com"
      refute Base.url_decode64!(cache |> String.split(".") |> Enum.at(1), padding: false) =~ "ada"
      {_browser, conn} = get(browser, "/get-session")
      assert json(conn)["user"]["email"] == "ada@example.com"
    end
  end

  # Re-signs the cache with a changed payload, as only the server could.
  defp rewrite_cache(browser, fun) do
    config = Auth.config()

    {:ok, json} =
      Crypto.verify(config, "session-data", cookie(browser, "app_session_cache"))

    payload = json |> JSON.decode!() |> fun.() |> JSON.encode!()

    %{
      browser
      | cookies:
          Map.put(
            browser.cookies,
            "app_session_cache",
            Crypto.sign(config, "session-data", payload)
          )
    }
  end
end
