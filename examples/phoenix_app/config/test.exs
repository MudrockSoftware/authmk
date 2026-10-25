import Config

config :argon2_elixir, t_cost: 1, m_cost: 8

config :phoenix_app, PhoenixApp.Auth,
  secret: "gQ4n9fvOWNIrCTcEva1RdFmyIWL0wrF9knYFdm4IX9c",
  background: :inline,
  rate_limit: [enabled: false],
  # GitHub is played by a Req.Test stub (see test/phoenix_app_web/social_test.exs).
  social_providers: [github: [client_id: "github-id", client_secret: "github-secret"]],
  advanced: [http_options: [plug: {Req.Test, PhoenixApp.GitHub}]]

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :phoenix_app, PhoenixApp.Repo,
  database: Path.expand("../phoenix_app_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :phoenix_app, PhoenixAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "x7JfjWJ/XgINMm9+2Ze4chMbZzHWF+SCWzFoGLKueG5bDZ1cbBJ1uxS9TKPA+Q9P",
  server: false

# In test we don't send emails
config :phoenix_app, PhoenixApp.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :phoenix_app, PhoenixApp.SMS, adapter: :test
