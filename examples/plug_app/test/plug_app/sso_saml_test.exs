defmodule PlugApp.SSOSAMLTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  alias Authmk.Testing.SAMLIdP

  test "people at globex.example sign in with its SAML identity provider" do
    start = post_json("/auth/sign-in/sso", %{email: "grace@globex.example", callback_url: "/"})
    url = json(start)["url"]
    assert "https://idp.globex.example/saml/sso?SAMLRequest=" <> _ = url

    # The provider's page posts the signed response back, as a form, from
    # its own site: none of our cookies come with it.
    %{acs_url: acs_url, params: params} =
      SAMLIdP.response(url,
        issuer: "https://idp.globex.example/saml",
        private_key: File.read!("test/fixtures/saml_idp.key"),
        name_id: "grace@globex.example",
        attributes: %{"email" => ["grace@globex.example"], "displayName" => ["Grace Hopper"]}
      )

    acs =
      Plug.Test.conn(:post, URI.parse(acs_url).path, URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("origin", "https://idp.globex.example")
      |> call()

    [finish] = get_resp_header(acs, "location")

    # The browser follows, with the cookie from the start.
    signed_in = get_path(URI.parse(finish).path <> "?" <> URI.parse(finish).query, cookies(start))
    assert get_resp_header(signed_in, "location") == ["/"]
    assert json(get_path("/me", cookies(signed_in)))["email"] == "grace@globex.example"
  end

  test "the provider's admin gets this app's SAML metadata" do
    conn = get_path("/auth/sso/saml2/metadata/globex")
    assert conn.status == 200
    assert conn.resp_body =~ "/auth/sso/saml2/acs/globex"
  end
end
