defmodule PhoenixAppWeb.SSOSAMLTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  alias Authmk.Testing.SAMLIdP

  test "people at globex.example sign in with its SAML identity provider", %{conn: conn} do
    start = post(conn, "/auth/sign-in/sso", %{email: "grace@globex.example", callback_url: "/"})
    url = json_response(start, 200)["url"]
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

    finish =
      build_conn()
      |> put_req_header("origin", "https://idp.globex.example")
      |> post(URI.parse(acs_url).path, params)
      |> redirected_to()

    # The browser follows, with the cookie from the start.
    signed_in = start |> recycle() |> get(finish)
    assert redirected_to(signed_in) == "/"

    assert signed_in
           |> recycle()
           |> get("/auth/get-session")
           |> json_response(200)
           |> get_in(["user", "email"]) ==
             "grace@globex.example"
  end

  test "the provider's admin gets this app's SAML metadata", %{conn: conn} do
    body = conn |> get("/auth/sso/saml2/metadata/globex") |> response(200)
    assert body =~ "/auth/sso/saml2/acs/globex"
  end
end
