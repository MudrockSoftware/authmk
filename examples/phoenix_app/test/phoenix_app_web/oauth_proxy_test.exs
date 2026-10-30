defmodule PhoenixAppWeb.OAuthProxyTest do
  use PhoenixAppWeb.ConnCase, async: true

  # What a preview deployment sharing the proxy secret sends to GitHub as
  # `state`: its own state, and where production should send the code.
  defp from_preview(to) do
    secret = Application.fetch_env!(:phoenix_app, :oauth_proxy)[:secret]
    Plug.Crypto.sign(secret, "authmk-oauth-proxy", %{"state" => "preview-state", "to" => to})
  end

  test "GitHub's callback goes back to the preview that started the sign-in", %{conn: conn} do
    state = from_preview("http://localhost:4100/auth/callback/github")
    conn = get(conn, "/auth/callback/github", code: "the-code", state: state)

    assert redirected_to(conn) ==
             "http://localhost:4100/auth/callback/github?code=the-code&state=preview-state"
  end

  test "codes never go to deployments production doesn't trust", %{conn: conn} do
    state = from_preview("https://evil.example/auth/callback/github")
    conn = get(conn, "/auth/callback/github", code: "the-code", state: state)

    assert redirected_to(conn) =~ "http://localhost:4000/auth/error?error=state_"
  end
end
