defmodule Authmk.Providers.LinearTest do
  use Authmk.Test.ProviderCase, provider: :linear

  alias Authmk.Test.{FakeProvider, Repo}

  @viewer %{
    "id" => "2d1f3b0c-6a5e-4c4f-9b1a-7e8d9c0b1a2f",
    "name" => "Ada Lovelace",
    "email" => "ada@example.com",
    "avatarUrl" => "https://public.linear.app/ada.png",
    "active" => true
  }

  # Answers the GraphQL viewer query, and checks that it was asked.
  defp graphql(answer) do
    fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      %{"query" => "query { viewer {" <> _fields} = JSON.decode!(body)
      answer
    end
  end

  test "signs in as the GraphQL viewer", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, post_routes: %{"/graphql" => graphql(%{"data" => %{"viewer" => @viewer}})})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "linear.app/oauth/authorize"
    assert query["scope"] == "read"
    refute Map.has_key?(query, "code_challenge")

    assert user["email"] == "ada@example.com"
    assert user["email_verified"] == false
    assert user["name"] == "Ada Lovelace"
    assert user["image"] == "https://public.linear.app/ada.png"
  end

  test "a GraphQL error refuses sign-in", %{browser: browser, auth: auth} do
    errors = %{"data" => nil, "errors" => [%{"message" => "Authentication required"}]}
    FakeProvider.stub(auth, post_routes: %{"/graphql" => graphql(errors)})

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "linear", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/linear", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=unable_to_get_user_info"
    assert Repo.aggregate("users", :count) == 0
  end
end
