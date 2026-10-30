defmodule PlugApp.OAuthProxyTest do
  use PlugApp.ConnCase, async: true

  # What a preview deployment sharing the proxy secret sends to Google as
  # `state`: its own state, and where production should send the code.
  defp from_preview(to) do
    secret = Application.fetch_env!(:plug_app, :oauth_proxy)[:secret]
    Plug.Crypto.sign(secret, "authmk-oauth-proxy", %{"state" => "preview-state", "to" => to})
  end

  test "Google's callback goes back to the preview that started the sign-in" do
    state = from_preview("http://localhost:4100/auth/callback/google")
    conn = get_path("/auth/callback/google?" <> URI.encode_query(code: "the-code", state: state))

    assert conn.status == 302

    assert get_resp_header(conn, "location") == [
             "http://localhost:4100/auth/callback/google?code=the-code&state=preview-state"
           ]
  end

  test "codes never go to deployments production doesn't trust" do
    state = from_preview("https://evil.example/auth/callback/google")
    conn = get_path("/auth/callback/google?" <> URI.encode_query(code: "the-code", state: state))

    [location] = get_resp_header(conn, "location")
    assert location =~ "http://localhost:4001/auth/error?error=state_"
  end
end
