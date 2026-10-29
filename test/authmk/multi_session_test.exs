defmodule Authmk.MultiSessionTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.MultiSession, maximum_sessions: 2}]
  end

  @moduletag auth: Auth

  # Accounts made elsewhere, then signed in on this device.
  defp account(email) do
    {_other, _user} = sign_up(Browser.new(Auth), %{email: email, name: email})
    :ok
  end

  defp sign_in(browser, email) do
    {browser, conn} = post(browser, "/sign-in/email", %{email: email, password: "correct horse"})
    assert json(conn)["user"]["email"] == email
    browser
  end

  defp active_email(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]["email"]
  end

  defp device_sessions(browser) do
    {_browser, conn} = get(browser, "/multi-session/list-device-sessions")
    json(conn)
  end

  test "two accounts on one device: list, switch, revoke", %{browser: browser} do
    :ok = account("ada@example.com")
    :ok = account("grace@example.com")
    browser = browser |> sign_in("ada@example.com") |> sign_in("grace@example.com")

    assert active_email(browser) == "grace@example.com"
    sessions = device_sessions(browser)
    assert Enum.map(sessions, & &1["user"]["email"]) == ["grace@example.com", "ada@example.com"]
    refute Enum.any?(sessions, &Map.has_key?(&1["session"], "token"))

    ada = Enum.find(sessions, &(&1["user"]["email"] == "ada@example.com"))["session"]["id"]
    {browser, conn} = post(browser, "/multi-session/set-active", %{session_id: ada})
    assert json(conn)["user"]["email"] == "ada@example.com"
    assert active_email(browser) == "ada@example.com"

    # Revoking the active one switches to the other.
    {browser, _conn} = post(browser, "/multi-session/revoke", %{session_id: ada})
    assert active_email(browser) == "grace@example.com"
    assert length(device_sessions(browser)) == 1
  end

  test "at most maximum_sessions: the oldest is signed out", %{browser: browser} do
    for email <- ~w(a@example.com b@example.com c@example.com), do: :ok = account(email)

    browser =
      browser |> sign_in("a@example.com") |> sign_in("b@example.com") |> sign_in("c@example.com")

    assert Enum.map(device_sessions(browser), & &1["user"]["email"]) == [
             "c@example.com",
             "b@example.com"
           ]

    # a's session is gone, not just forgotten (plus the three sign-ups').
    assert Repo.aggregate("sessions", :count) == 3 + 2
  end

  test "signing out signs every account on the device out", %{browser: browser} do
    :ok = account("ada@example.com")
    :ok = account("grace@example.com")
    browser = browser |> sign_in("ada@example.com") |> sign_in("grace@example.com")

    {browser, _conn} = post(browser, "/sign-out")
    assert active_email(browser) == nil
    assert device_sessions(browser) == []
    # Only the sign-ups' sessions on their own devices are left.
    assert Repo.aggregate("sessions", :count) == 2
  end

  test "sessions of other devices can't be switched to", %{browser: browser} do
    :ok = account("ada@example.com")
    browser = sign_in(browser, "ada@example.com")

    {elsewhere, _user} = sign_up(Browser.new(Auth), %{email: "eve@example.com"})
    {_elsewhere, conn} = get(elsewhere, "/get-session")
    eve_session = json(conn)["session"]["id"]

    {_browser, conn} = post(browser, "/multi-session/set-active", %{session_id: eve_session})
    assert json(conn)["error"]["code"] == "session_not_found"

    # Nor through a forged list.
    forged = %{browser | cookies: Map.put(browser.cookies, "authmk.device_sessions", "garbage")}
    assert device_sessions(forged) == []
  end
end
