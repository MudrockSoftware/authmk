import Config

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
  secret_key_base: "l9U155gS/Kt8yy1I/emx/IHd8SU21lds9fmDpp6V/4gTrOBBypiBv49++AZMFkiM",
  server: false

# In test we don't send emails
config :phoenix_app, PhoenixApp.Mailer, adapter: Swoosh.Adapters.Test

# Send emails from the test process, so tests can assert on them.
config :phoenix_app, PhoenixApp.Auth, background: :inline, rate_limit: [enabled: false]

# Fast, insecure password hashing. Tests only.
config :argon2_elixir, t_cost: 1, m_cost: 8, parallelism: 1

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
