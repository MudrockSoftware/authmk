defmodule PhoenixAppWeb.OneTapTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  # Plays Google: its keys, and an ID token signed with them.
  defp google_credential do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_kty, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    keys = %{"keys" => [Map.merge(public, %{"kid" => "google-key", "alg" => "RS256"})]}
    Req.Test.stub(PhoenixApp.Providers, &Req.Test.json(&1, keys))

    now = System.system_time(:second)

    claims = %{
      "iss" => "https://accounts.google.com",
      "aud" => "google-id",
      "sub" => "g-1",
      "email" => "ada@example.com",
      "email_verified" => true,
      "name" => "Ada",
      "iat" => now,
      "exp" => now + 600
    }

    {_alg, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "google-key"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  test "Google posts the credential in redirect mode, and the user lands signed in", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("origin", "https://accounts.google.com")
      |> put_req_cookie("g_csrf_token", "csrf-1")
      |> post("/auth/one-tap/redirect", %{credential: google_credential(), g_csrf_token: "csrf-1"})

    assert redirected_to(conn) == "/"

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200) =~ "Signed in as ada@example.com"
  end
end
