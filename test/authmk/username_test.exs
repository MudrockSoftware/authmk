defmodule Authmk.UsernameTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.Username, Authmk.Plugins.TwoFactor]
  end

  @moduletag auth: Auth

  @password "correct horse"

  defp sign_up_as(browser, username, email \\ "ada@example.com") do
    post(browser, "/sign-up/email", %{
      email: email,
      password: @password,
      name: "Ada",
      username: username
    })
  end

  defp sign_in_as(browser, username, password \\ @password) do
    post(browser, "/sign-in/username", %{username: username, password: password})
  end

  test "sign up with a username, then sign in with it", %{browser: browser} do
    {browser, conn} = sign_up_as(browser, "Ada.Lovelace")
    user = json(conn)["user"]

    # Stored normalized; shown as typed.
    assert user["username"] == "ada.lovelace"
    assert user["display_username"] == "Ada.Lovelace"

    {browser, _conn} = post(browser, "/sign-out")

    {browser, conn} = sign_in_as(browser, "ADA.lovelace")
    assert json(conn)["user"]["email"] == "ada@example.com"

    {_browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]["username"] == "ada.lovelace"
  end

  test "wrong usernames and wrong passwords fail the same way", %{browser: browser} do
    {browser, _conn} = sign_up_as(browser, "ada")
    {browser, _conn} = post(browser, "/sign-out")

    for {username, password} <- [
          {"ada", "wrong password"},
          {"nobody", @password},
          {"no way!", @password}
        ] do
      {_browser, conn} = sign_in_as(browser, username, password)
      assert conn.status == 401
      assert json(conn)["error"]["code"] == "invalid_credentials"
    end
  end

  test "two-factor authentication applies to username sign-in", %{browser: browser} do
    {browser, _conn} = sign_up_as(browser, "ada")
    {browser, conn} = post(browser, "/two-factor/enable", %{password: @password})

    %{"secret" => secret} =
      json(conn)["totp_uri"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    code = NimbleTOTP.verification_code(Base.decode32!(secret, padding: false))
    {browser, _conn} = post(browser, "/two-factor/verify-totp", %{code: code})
    {browser, _conn} = post(browser, "/sign-out")

    {_browser, conn} = sign_in_as(browser, "ada")
    assert json(conn)["two_factor_redirect"] == true
  end

  test "usernames are unique, whatever the case", %{browser: browser} do
    {_browser, _conn} = sign_up_as(browser, "ada")

    {_browser, conn} = sign_up_as(Browser.new(Auth), "ADA", "other@example.com")
    assert json(conn)["error"]["code"] == "username_taken"
    assert Repo.aggregate("users", :count) == 1
  end

  test "length and characters are checked", %{browser: browser} do
    for {username, code} <- [
          {"ab", "username_too_short"},
          {String.duplicate("a", 31), "username_too_long"},
          {"ada lovelace", "invalid_username"},
          {"ada@home", "invalid_username"}
        ] do
      {_browser, conn} = sign_up_as(browser, username)
      assert json(conn)["error"]["code"] == code
    end

    assert Repo.aggregate("users", :count) == 0
  end

  test "availability", %{browser: browser} do
    {browser, _conn} = sign_up_as(browser, "ada")

    {browser, conn} = post(browser, "/is-username-available", %{username: "Ada"})
    assert json(conn) == %{"available" => false}

    {browser, conn} = post(browser, "/is-username-available", %{username: "grace"})
    assert json(conn) == %{"available" => true}

    {_browser, conn} = post(browser, "/is-username-available", %{username: "no way"})
    assert json(conn)["error"]["code"] == "invalid_username"
  end

  test "users change their username, but not to a taken one", %{browser: browser} do
    {_other, _conn} = sign_up_as(Browser.new(Auth), "grace", "grace@example.com")
    {browser, _conn} = sign_up_as(browser, "ada")

    {browser, conn} = post(browser, "/update-user", %{username: "Grace"})
    assert json(conn)["error"]["code"] == "username_taken"

    # Their own username, in another case, is fine.
    {browser, conn} = post(browser, "/update-user", %{username: "ADA"})
    assert json(conn)["user"]["username"] == "ada"

    {browser, conn} =
      post(browser, "/update-user", %{username: "countess", display_username: "The Countess"})

    assert json(conn)["user"]["username"] == "countess"
    assert json(conn)["user"]["display_username"] == "The Countess"

    {browser, _conn} = post(browser, "/sign-out")
    {_browser, conn} = sign_in_as(browser, "countess")
    assert json(conn)["user"]["email"] == "ada@example.com"
  end
end

defmodule Authmk.UsernameOptionsTest do
  use Authmk.EmulationCase, async: true

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Username,
         min_length: 5,
         max_length: 8,
         immutable: true,
         disable_availability_check: true,
         validator: &__MODULE__.lowercase_letters?/1,
         normalizer: &String.trim/1,
         display_username_validator: &__MODULE__.short?/1,
         display_username_normalizer: &String.upcase/1}
      ]

    def lowercase_letters?(username), do: username =~ ~r/^[a-z]+$/
    def short?(display), do: String.length(display) <= 10
  end

  @moduletag auth: Auth

  defp sign_up_as(browser, attrs) do
    post(
      browser,
      "/sign-up/email",
      Map.merge(%{email: "ada@example.com", password: "correct horse", name: "Ada"}, attrs)
    )
  end

  test "custom rules and normalizers", %{browser: browser} do
    {_browser, conn} = sign_up_as(browser, %{username: "Ada12"})
    assert json(conn)["error"]["code"] == "invalid_username"

    {_browser, conn} = sign_up_as(browser, %{username: "abc"})
    assert json(conn)["error"]["code"] == "username_too_short"

    {_browser, conn} =
      sign_up_as(browser, %{username: "  adalove  ", display_username: "a much too long name"})

    assert json(conn)["error"]["code"] == "invalid_display_username"

    {_browser, conn} = sign_up_as(browser, %{username: "  adalove  ", display_username: "ada"})
    assert json(conn)["user"]["username"] == "adalove"
    assert json(conn)["user"]["display_username"] == "ADA"
  end

  test "a username can't change once set", %{browser: browser} do
    {browser, _conn} = sign_up_as(browser, %{username: "adalove"})

    {browser, conn} = post(browser, "/update-user", %{username: "lovelace"})
    assert conn.status == 403
    assert json(conn)["error"]["code"] == "username_immutable"

    # Other fields still change.
    {_browser, conn} = post(browser, "/update-user", %{name: "Ada L."})
    assert json(conn)["user"]["name"] == "Ada L."
  end

  test "users who have none yet may set one", %{browser: browser} do
    {browser, _conn} = sign_up_as(browser, %{})
    {_browser, conn} = post(browser, "/update-user", %{username: "adalove"})
    assert json(conn)["user"]["username"] == "adalove"
  end

  test "the availability check can be turned off", %{browser: browser} do
    {_browser, conn} = post(browser, "/is-username-available", %{username: "adalove"})
    assert conn.status == 404
  end
end
