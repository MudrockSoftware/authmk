defmodule PlugApp.SSOTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  test "people at acme.example sign in with acme's identity provider" do
    # Discovery first: the provider's endpoints come from its issuer.
    PlugApp.IdentityProvider.stub(nil)
    start = post_json("/auth/sign-in/sso", %{email: "ada@acme.example", callback_url: "/"})
    url = json(start)["url"]
    assert "https://idp.acme.example/authorize?" <> _ = url

    # The user signs in there; it sends them back with a code.
    query = URI.decode_query(URI.parse(url).query)
    PlugApp.IdentityProvider.stub(query["nonce"])

    callback =
      get_path(
        "/auth/sso/callback/acme?" <> URI.encode_query(code: "a-code", state: query["state"]),
        cookies(start)
      )

    assert get_resp_header(callback, "location") == ["/"]

    assert json(get_path("/me", cookies(callback)))["email"] == "ada@acme.example"
  end

  test "other domains have no single sign-on" do
    conn = post_json("/auth/sign-in/sso", %{email: "ada@other.example"})
    assert json(conn)["error"]["code"] == "sso_provider_not_found"
  end
end
