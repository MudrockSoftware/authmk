# Testing

Your app's tests can use authmk the way your users do: through its
endpoints, with real sessions and real emails. authmk ships helpers for the
parts that are slow or outside your app: signing a user in, catching codes
and links, and playing passkeys, wallets and SAML identity providers.

The example apps test every feature this way. Their tests are the best
reference: `examples/plug_app/test` (Plug.Test) and
`examples/phoenix_app/test` (ConnTest and LiveViewTest).

## Test config

A typical `config/test.exs`:

```elixir
config :my_app, MyApp.Auth,
  secret: "a fixed test-only secret, at least 32 characters",
  # Emails and other side work run in the test process.
  background: :inline,
  # Counters live in memory across tests; turn limits off.
  rate_limit: [enabled: false],
  # OAuth providers, captchas and Have I Been Pwned answer from a stub.
  advanced: [http_options: [plug: {Req.Test, MyApp.Providers}]]

# Cheap password hashing, for speed.
config :argon2_elixir, t_cost: 1, m_cost: 8
```

authmk writes through your repo, so the Ecto SQL sandbox works as usual.

## Signing a user in

Most tests only need a signed-in user. `Authmk.Testing` creates one and a
session directly, without the sign-up and sign-in endpoints:

  * `create_user/2` - a user with a unique email, a verified email and the
    name `"Test User"`, unless you pass others. `:password` gives them a
    password they can sign in with. Database hooks run as in the app.
  * `sign_in/4` - a new session for the user, with its cookies on the
    test conn.
  * `create_session/3` - the session and its cookies, for other clients.
  * `get_user_by/2` and `list_sessions/2` - to check what changed.

Use it in tests and seeds only, never in production code.

### With Phoenix.ConnTest

```elixir
test "a signed-in user sees the account page", %{conn: conn} do
  user = Authmk.Testing.create_user(MyApp.Auth, email: "ada@example.com", name: "Ada")

  conn = conn |> Authmk.Testing.sign_in(MyApp.Auth, user) |> get(~p"/account")
  assert html_response(conn, 200) =~ "Ada"
end
```

### With Phoenix.LiveViewTest

The cookies stay on the conn, so `live/2` mounts as that user:

```elixir
test "admins only", %{conn: conn} do
  ada = Authmk.Testing.create_user(MyApp.Auth, email: "ada@example.com")

  assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings")

  {:ok, _view, html} = conn |> Authmk.Testing.sign_in(MyApp.Auth, ada) |> live(~p"/settings")
  assert html =~ "ada@example.com"
end
```

### With Plug.Test

```elixir
test "a signed-in user reaches the protected page" do
  user = Authmk.Testing.create_user(MyApp.Auth, email: "ada@example.com")

  conn =
    conn(:get, "/me")
    |> Authmk.Testing.sign_in(MyApp.Auth, user)
    |> MyApp.Router.call(MyApp.Router.init([]))

  assert conn.status == 200
end
```

## Going through the endpoints

To test the flows themselves, call the auth routes as a browser would.
Requests that change something and carry cookies need an `Origin` header
from a trusted origin, or authmk refuses them with `invalid_origin` (see
[Security](security.md#trusted-origins-and-csrf)):

```elixir
defp from_browser(conn), do: put_req_header(conn, "origin", "http://localhost:4000")

test "sign up, then sign in", %{conn: conn} do
  user = %{email: "ada@example.com", password: "correct horse", name: "Ada"}
  conn = conn |> from_browser() |> post("/auth/sign-up/email", user)
  assert conn.status == 200

  # recycle/1 keeps the session cookie, like a browser.
  conn = conn |> recycle() |> get(~p"/account")
  assert html_response(conn, 200) =~ "ada@example.com"
end
```

## Emails

If your send callbacks use a Swoosh mailer, its test adapter works as
usual (`config :my_app, MyApp.Mailer, adapter: Swoosh.Adapters.Test`):

```elixir
import Swoosh.TestAssertions

assert_email_sent(fn email ->
  assert email.subject == "Reset your password"
  assert email.text_body =~ "http://localhost:4000/auth/reset-password/"
end)
```

To get the code or link itself, without parsing an email,
`Authmk.Testing.Inbox` catches the maps authmk hands your callbacks. Point
a callback at `Inbox.deliver/2` in tests:

```elixir
# In your auth module
{Authmk.Plugins.EmailOTP, send_otp: &__MODULE__.send_email_code/2}

def send_email_code(message, ctx) do
  if Application.get_env(:my_app, :capture_auth_messages),
    do: Authmk.Testing.Inbox.deliver(message, ctx),
    else: MyApp.Mailer.deliver_code(message)
end
```

Then, in the test that triggered it:

```elixir
%{otp: code} = Authmk.Testing.Inbox.receive!(to: "ada@example.com")
%{url: url} = Authmk.Testing.Inbox.receive!(to: "bob@example.com")
assert Authmk.Testing.Inbox.empty?()
```

`receive!/1` waits `:timeout` ms (default 100) and raises when nothing came.
Messages go to the test process, even from a background task.

## SMS

`Authmk.SMS.Test` sends each text to the test process as
`{:sms, to, body}`. Pick the sender from config:

```elixir
# In your auth module
def send_phone_code(message, ctx),
  do: Authmk.SMS.send_otp(Application.get_env(:my_app, :sms_sender), message, ctx)

# config/test.exs
config :my_app, :sms_sender, Authmk.SMS.Test
```

```elixir
number = "+14155550123"
conn = conn |> from_browser() |> post("/auth/phone-number/send-otp", %{phone_number: number})
assert_received {:sms, ^number, body}
[code] = Regex.run(~r/^\d+/, body)
```

## Outside services

Every outbound request authmk makes (OAuth providers, captchas, Have I Been
Pwned, SSO discovery) uses `Req` with your `advanced: [http_options: ...]`.
With the `Req.Test` plug from the config above, each test decides the
answer. The example apps answer nothing by default, in their case
templates:

```elixir
Req.Test.stub(MyApp.Providers, &Plug.Conn.send_resp(&1, 200, ""))
```

and tests that need more stub it again. A captcha that passes:

```elixir
Req.Test.stub(MyApp.Providers, &Req.Test.json(&1, %{"success" => true}))

conn
|> from_browser()
|> put_req_header("x-captcha-response", "token-from-the-widget")
|> post("/auth/request-password-reset", %{email: "ada@example.com"})
```

## Passkeys

`Authmk.Testing.FakeAuthenticator` is a software passkey. It answers the
registration and sign-in options like a browser would. Its `origin:` must
be your `base_url`:

```elixir
alias Authmk.Testing.FakeAuthenticator

authenticator = FakeAuthenticator.new(origin: "http://localhost:4000")

# Signed in: register.
conn = conn |> recycle() |> from_browser() |> post("/auth/passkey/generate-register-options")
response = FakeAuthenticator.register(authenticator, json_response(conn, 200))
conn = conn |> recycle() |> from_browser() |> post("/auth/passkey/verify-registration", %{response: response})

# Later: sign in. Keep the returned authenticator; its counter moved.
conn = conn |> recycle() |> from_browser() |> post("/auth/passkey/generate-authenticate-options")
{authenticator, response} = FakeAuthenticator.authenticate(authenticator, json_response(conn, 200))
conn = conn |> recycle() |> from_browser() |> post("/auth/passkey/verify-authentication", %{response: response})
```

`new/1` also takes `user_verified:`, `backup_eligible:`, `aaguid:` and
`counts: false` (a sign count that stays 0, like most platform passkeys).

## Sign-In with Ethereum

`Authmk.Testing.FakeWallet` signs SIWE messages like a wallet's
`personal_sign`. It needs the same deps as `Authmk.Plugins.SIWE`. With the
plug app's `post_json/2` and `json/1` helpers:

```elixir
alias Authmk.Testing.FakeWallet

wallet = FakeWallet.new()
conn = post_json("/auth/siwe/nonce", %{wallet_address: wallet.address, chain_id: 1})
message = FakeWallet.message(wallet, domain: "localhost:4001", nonce: json(conn)["nonce"])

post_json("/auth/siwe/verify", %{
  message: message,
  signature: FakeWallet.sign(wallet, message),
  wallet_address: wallet.address,
  chain_id: 1
})
```

## SAML single sign-on

`Authmk.Testing.SAMLIdP` plays a SAML identity provider. Generate a
test-only key pair, put its certificate in the provider's config, and sign
responses with the key. Again with the plug app's helpers:

```elixir
start = post_json("/auth/sign-in/sso", %{email: "grace@globex.example", callback_url: "/"})

%{acs_url: acs_url, params: params} =
  Authmk.Testing.SAMLIdP.response(json(start)["url"],
    issuer: "https://idp.globex.example/saml",
    private_key: File.read!("test/fixtures/saml_idp.key"),
    name_id: "grace@globex.example",
    attributes: %{"email" => ["grace@globex.example"]}
  )
```

Post `params` as a form to `acs_url`, then follow the redirect with the
cookies from `start`. `response/2` also takes `encrypt_for:` (your
certificate) to send the assertion encrypted, and `build/1` makes
identity-provider-initiated responses. `examples/plug_app/test/plug_app/sso_saml_test.exs`
runs the whole flow, sign-out included.

## The Security plugin

The Security plugin counts failed sign-ins per client IP, in memory, and
its counters outlast a test. Many tests with wrong passwords from the same
address can trip credential-stuffing blocking (`too_many_attempts`) in
later tests. Give those tests their own address; `recycle/1` keeps it:

```elixir
conn = %{build_conn() | remote_ip: {10, 0, 0, 42}}
```

The same goes for rate limits, if you leave them on to test one.
