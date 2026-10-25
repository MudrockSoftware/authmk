defmodule Authmk.UserTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    schema: [
      user: [
        additional_fields: [
          locale: [type: :string],
          role: [type: :string, default: "member", input: false]
        ]
      ]
    ],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    session: [fresh_age: 300],
    user: [delete_user: [enabled: true]]
end

defmodule Authmk.UserTest.VerifiedDeleteAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    user: [delete_user: [enabled: true, verify_with_email: true]]

  @impl Authmk
  def send_delete_account_verification(link, _ctx),
    do: send(self(), {:email, :delete_account, link})
end

defmodule Authmk.UserTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Repo

  @moduletag auth: Authmk.UserTest.Auth

  test "update-user changes input fields only", %{browser: browser} do
    {browser, user} = sign_up(browser, %{locale: "tr"})
    assert user["locale"] == "tr"
    assert user["role"] == "member"

    {_browser, conn} =
      post(browser, "/update-user", %{
        name: "Ada L.",
        locale: "en",
        role: "admin",
        email: "x@example.com"
      })

    user = json(conn)["user"]
    assert user["name"] == "Ada L."
    assert user["locale"] == "en"
    assert user["role"] == "member"
    assert user["email"] == "ada@example.com"
  end

  test "update-user reports invalid values", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, conn} = post(browser, "/update-user", %{name: String.duplicate("a", 300)})

    assert conn.status == 422

    assert ["should be at most 255 character(s)"] =
             json(conn)["error"]["details"]["fields"]["name"]
  end

  test "list-accounts shows the password account without its hash", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, conn} = get(browser, "/list-accounts")

    assert [account] = json(conn)
    assert account["provider_id"] == "credential"
    refute Map.has_key?(account, "password")
  end

  test "change-email is off unless enabled", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, conn} = post(browser, "/change-email", %{new_email: "new@example.com"})

    assert conn.status == 404
    assert json(conn)["error"]["code"] == "feature_disabled"
  end

  describe "delete-user" do
    test "with the password deletes the user and everything they own", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, conn} = post(browser, "/delete-user", %{password: "correct horse"})

      assert json(conn) == %{"success" => true}
      assert cookie(browser, "authmk.session_token") == nil

      for table <- ["users", "sessions", "accounts"] do
        assert Repo.aggregate(table, :count) == 0
      end
    end

    test "with a wrong password does nothing", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {_browser, conn} = post(browser, "/delete-user", %{password: "wrong"})

      assert json(conn)["error"]["code"] == "invalid_password"
      assert Repo.aggregate("users", :count) == 1
    end

    test "without a password needs a fresh session", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      ten_minutes_ago = DateTime.add(DateTime.utc_now(), -600)
      Repo.update_all("sessions", set: [inserted_at: ten_minutes_ago])

      {_browser, conn} = post(browser, "/delete-user")
      assert json(conn)["error"]["code"] == "session_not_fresh"

      {browser, _conn} =
        post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

      {_browser, conn} = post(browser, "/delete-user")
      assert json(conn) == %{"success" => true}
    end
  end

  describe "delete-user with email confirmation" do
    @describetag auth: Authmk.UserTest.VerifiedDeleteAuth

    test "deletes only after the link is opened by the same user", %{browser: browser} do
      {ada, _user} = sign_up(browser)
      {bob, _user} = sign_up(browser, %{email: "bob@example.com"})

      {ada, conn} = post(ada, "/delete-user", %{password: "correct horse"})
      assert json(conn)["message"] == "Verification email sent"
      assert Repo.aggregate("users", :count) == 2
      link = assert_email(:delete_account)

      {_bob, conn} = get(bob, "/delete-user/callback", %{token: link.token})
      assert json(conn)["error"]["code"] == "invalid_token"

      {_browser, _conn} = post(ada, "/delete-user", %{password: "correct horse"})
      link = assert_email(:delete_account)

      {_ada, conn} =
        get(ada, "/delete-user/callback", %{token: link.token, callback_url: "/goodbye"})

      assert redirected_to(conn) == "/goodbye"
      assert Repo.aggregate("users", :count) == 1
    end
  end
end
