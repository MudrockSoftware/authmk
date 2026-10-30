defmodule Authmk.DashboardHealthTest do
  # Health checks: what this node knows (deliveries, certificates and
  # secrets about to expire, storage, background jobs, the audit log), and
  # what the providers answer (fakes behind Req.Test).
  use Authmk.EmulationCase, async: true

  import Authmk.Test.DashboardHelpers

  alias Authmk.Test.Browser
  alias Authmk.Testing

  defmodule Fixtures do
    @moduledoc false

    # A certificate that expires in ten days.
    @expiring (
                today = Date.utc_today()
                from = Date.add(today, -1)
                to = Date.add(today, 10)

                %{cert: der} =
                  :public_key.pkix_test_root_cert(~c"Expiring IdP", [
                    {:validity, {{from.year, from.month, from.day}, {to.year, to.month, to.day}}},
                    {:digest, :sha256},
                    {:key, {:rsa, 2048, 65_537}}
                  ])

                :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
              )

    # Client secrets that are JWTs say when they expire (Apple's do).
    @expired_secret Enum.join(
                      [
                        Base.url_encode64(~s({"alg":"ES256"}), padding: false),
                        Base.url_encode64(~s({"exp":1600000000}), padding: false),
                        "signature"
                      ],
                      "."
                    )

    def expiring, do: @expiring
    def expired_secret, do: @expired_secret
  end

  defmodule Auth do
    alias Authmk.DashboardHealthTest.Fixtures

    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      secondary_storage: Authmk.Storage.ETS,
      email_verification: [send_on_sign_up: true],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]],
      social_providers: [
        github: [client_id: "github-id", client_secret: "github-secret"],
        gitlab: [
          client_id: "gitlab-id",
          client_secret: Fixtures.expired_secret()
        ]
      ],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Admin,
        Authmk.Plugins.Organization,
        {Authmk.Plugins.SSO,
         default_providers: [
           [
             provider_id: "okta",
             issuer: "https://idp.acme.example",
             client_id: "okta-id",
             client_secret: "okta-secret"
           ],
           [
             provider_id: "adfs",
             saml: [
               entity_id: "https://adfs.acme.example/saml",
               sso_url: "https://adfs.acme.example/sso",
               certificates: [Fixtures.expiring()]
             ]
           ]
         ]}
      ]

    # Reset emails fail; verification emails aren't implemented at all.
    @impl Authmk
    def send_reset_password(_data, _ctx), do: {:error, :smtp_down}
  end

  @moduletag auth: Auth
  @moduletag :capture_log

  setup do
    %{admin: Testing.create_user(Auth, email: "admin@example.com", role: "admin")}
  end

  defp check(checks, name), do: Enum.find(checks, &(&1["name"] == name))

  test "before anything is sent, senders are unknown", %{admin: admin} do
    {200, %{"checks" => checks}} = get_json(Auth, "health", admin)
    assert %{"status" => "unknown"} = check(checks, "Email and SMS")
  end

  test "on this node: deliveries, expiring secrets, storage, jobs, the audit log", %{
    browser: browser,
    admin: admin
  } do
    {_browser, _user} = sign_up(browser)
    Browser.post(Browser.new(Auth), "/request-password-reset", %{email: "ada@example.com"})

    {200, %{"checks" => checks, "network" => false}} = get_json(Auth, "health", admin)

    assert %{"status" => "failing", "area" => "Email", "message" => "Not implemented" <> _} =
             check(checks, "send_verification_email")

    assert %{"status" => "failing", "message" => message} = check(checks, "send_reset_password")
    assert message =~ "smtp_down"

    assert %{"status" => "warning", "expires_at" => _} = check(checks, "adfs certificate")
    assert %{"status" => "failing"} = check(checks, "gitlab client secret")
    refute check(checks, "github client secret")

    assert %{"status" => "ok"} = check(checks, "Secondary storage")
    assert %{"status" => "ok"} = check(checks, "Background jobs")
    assert %{"status" => "warning"} = check(checks, "Audit log")

    # Nothing asked the providers.
    refute check(checks, "okta")
  end

  test "asking the providers: discovery and client credentials", %{admin: admin} do
    Req.Test.stub(Auth, fn conn ->
      case {conn.host, conn.request_path} do
        {"idp.acme.example", "/.well-known/openid-configuration"} ->
          Req.Test.json(conn, %{
            "issuer" => "https://idp.acme.example",
            "authorization_endpoint" => "https://idp.acme.example/authorize",
            "token_endpoint" => "https://idp.acme.example/token",
            "jwks_uri" => "https://idp.acme.example/jwks"
          })

        # A provider that knows the client: the code is what's wrong.
        {"idp.acme.example", "/token"} ->
          conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})

        {"github.com", "/login/oauth/access_token"} ->
          Req.Test.json(conn, %{"error" => "incorrect_client_credentials"})

        {"gitlab.com", _path} ->
          conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_client"})
      end
    end)

    {200, %{"checks" => checks, "network" => true}} = get_json(Auth, "health?network=true", admin)

    assert %{"status" => "ok", "area" => "SSO"} = check(checks, "okta")

    assert %{"status" => "failing", "message" => "It refused our client credentials."} =
             check(checks, "github")

    assert %{"status" => "failing"} = check(checks, "gitlab")
  end
end
