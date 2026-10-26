defmodule PlugApp.OneTapTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  # Plays Google: its keys, and an ID token signed with them.
  defp google_credential do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_kty, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    keys = %{"keys" => [Map.merge(public, %{"kid" => "google-key", "alg" => "RS256"})]}
    Req.Test.stub(PlugApp.Providers, &Req.Test.json(&1, keys))

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

  test "sign in with Google One Tap" do
    conn = post_json("/auth/one-tap/callback", %{id_token: google_credential()})
    assert json(conn)["user"]["email"] == "ada@example.com"

    assert json(get_path("/me", cookies(conn))) == %{
             "email" => "ada@example.com",
             "name" => "Ada"
           }
  end
end
