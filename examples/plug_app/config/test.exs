import Config

# An identity provider for single sign-on, played by the providers' stub.
config :plug_app, :sso_providers, [
  [
    provider_id: "acme",
    issuer: "https://idp.acme.example",
    client_id: "acme-id",
    client_secret: "acme-secret",
    domain: "acme.example"
  ],
  # A SAML 2.0 identity provider, played by Authmk.Testing.SAMLIdP with the
  # test-only key pair in test/fixtures.
  [
    provider_id: "globex",
    domain: "globex.example",
    saml: [
      entity_id: "https://idp.globex.example/saml",
      sso_url: "https://idp.globex.example/saml/sso",
      certificates: [File.read!("test/fixtures/saml_idp.crt")]
    ]
  ]
]

# This server plays production for the OAuth proxy, and
# http://localhost:4100 a preview deployment that signs in through it.
config :plug_app, :oauth_proxy,
  production_url: "http://localhost:4001",
  secret: "test-only OAuth proxy secret, 32+ bytes"

config :argon2_elixir, t_cost: 1, m_cost: 8

config :plug_app, PlugApp.Auth,
  trusted_origins: ["http://localhost:4100"],
  secret: "RkLUU1T_IwR_HoOrGRjMeoeZ2uoM7GqfbuVOVBLtkPo",
  background: :inline,
  rate_limit: [enabled: false],
  # Google is played by a Req.Test stub (see test/plug_app/one_tap_test.exs).
  social_providers: [google: [client_id: "google-id", client_secret: "google-secret"]],
  advanced: [http_options: [plug: {Req.Test, PlugApp.Providers}]]

config :plug_app, PlugApp.Repo, pool: Ecto.Adapters.SQL.Sandbox, pool_size: 5
config :plug_app, server: false
config :plug_app, PlugApp.Mailer, adapter: Swoosh.Adapters.Test
config :logger, level: :warning

config :plug_app, PlugApp.SMS, adapter: :test
