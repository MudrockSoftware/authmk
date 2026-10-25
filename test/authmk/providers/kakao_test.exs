defmodule Authmk.Providers.KakaoTest do
  use Authmk.Test.ProviderCase, provider: :kakao

  alias Authmk.Test.FakeProvider

  defp profile(account) do
    %{
      "id" => 123_456,
      "kakao_account" =>
        Map.merge(
          %{
            "email" => "ryan@example.com",
            "is_email_valid" => true,
            "is_email_verified" => true,
            "profile" => %{
              "nickname" => "Ryan",
              "profile_image_url" => "https://k.kakaocdn.net/big.jpg",
              "thumbnail_image_url" => "https://k.kakaocdn.net/small.jpg"
            }
          },
          account
        )
    }
  end

  test "signs in with the Kakao account's verified email", %{browser: browser} do
    %{url: url, user: user} =
      sign_in(browser, token_auth: :post, routes: %{"/v2/user/me" => profile(%{})})

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "kauth.kakao.com/oauth/authorize"
    assert query["scope"] == "account_email profile_image profile_nickname"
    refute Map.has_key?(query, "code_challenge")

    assert user["email"] == "ryan@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Ryan"
    assert user["image"] == "https://k.kakaocdn.net/big.jpg"
  end

  test "an email that is valid but not verified isn't verified", %{browser: browser} do
    %{user: user} =
      sign_in(browser, routes: %{"/v2/user/me" => profile(%{"is_email_verified" => false})})

    assert user["email_verified"] == false
  end

  test "falls back to the account name and the thumbnail", %{browser: browser} do
    account = %{
      "name" => "Ryan Kim",
      "profile" => %{"thumbnail_image_url" => "https://k/small.jpg"}
    }

    %{user: user} = sign_in(browser, routes: %{"/v2/user/me" => profile(account)})

    assert user["name"] == "Ryan Kim"
    assert user["image"] == "https://k/small.jpg"
  end

  test "without email consent there is no user", %{browser: browser} do
    FakeProvider.stub(browser.auth, routes: %{"/v2/user/me" => profile(%{"email" => nil})})

    {browser, conn} =
      post(browser, "/sign-in/social", %{provider: "kakao", callback_url: "/done"})

    {_browser, conn} = get(browser, "/callback/kakao", FakeProvider.approve(json(conn)["url"]))

    assert redirected_to(conn) =~ "error=email_not_found"
  end
end
