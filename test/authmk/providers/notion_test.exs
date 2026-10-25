defmodule Authmk.Providers.NotionTest do
  use Authmk.Test.ProviderCase, provider: :notion

  alias Authmk.Test.{FakeProvider, Repo}

  defp bot_owned_by(user) do
    fn conn ->
      # Notion refuses requests without an API version.
      ["2022-06-28"] = Plug.Conn.get_req_header(conn, "notion-version")

      %{
        "object" => "user",
        "type" => "bot",
        "bot" => %{"owner" => %{"type" => "user", "user" => user}}
      }
    end
  end

  @user %{
    "object" => "user",
    "id" => "e79a0b74-3aba-4149-9f74-0bb5791a6ee6",
    "type" => "person",
    "name" => "Ada Lovelace",
    "avatar_url" => "https://s3.us-west-2.amazonaws.com/public.notion-static.com/ada.png",
    "person" => %{"email" => "ada@example.com"}
  }

  test "signs in as the user who installed the integration", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, token_auth: :basic, routes: %{"/v1/users/me" => bot_owned_by(@user)})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "api.notion.com/v1/oauth/authorize"
    assert query["owner"] == "user"
    refute Map.has_key?(query, "code_challenge")

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://s3.us-west-2.amazonaws.com/public.notion-static.com/ada.png"
  end

  test "a user without a shared email can't sign in", %{browser: browser, auth: auth} do
    user = Map.delete(@user, "person")
    FakeProvider.stub(auth, routes: %{"/v1/users/me" => bot_owned_by(user)})

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "notion", callback_url: "/done"})

    url = json(conn)["url"]
    {_browser, conn} = get(browser, "/callback/notion", FakeProvider.approve(url))

    assert redirected_to(conn) =~ "error=email_not_found"
    assert Repo.aggregate("users", :count) == 0
  end
end
