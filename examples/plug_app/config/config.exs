import Config

config :plug_app, ecto_repos: [PlugApp.Repo]

config :plug_app, PlugApp.Repo, database: Path.expand("../plug_app_#{config_env()}.db", __DIR__)

config :plug_app, port: 4001

config :plug_app, PlugApp.Auth, base_url: "http://localhost:4001"

# Production reads the AUTHMK_SECRET environment variable instead.
if config_env() in [:dev, :test] do
  config :plug_app, PlugApp.Auth, secret: "ll4Yfzwe5z9ecv0m4k702fSqA-wlJfpV-kyYtSWn_7I"
end

config :plug_app, PlugApp.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false

if config_env() == :test do
  config :plug_app, PlugApp.Repo, pool: Ecto.Adapters.SQL.Sandbox, pool_size: 5
  config :plug_app, server: false
  config :plug_app, PlugApp.Mailer, adapter: Swoosh.Adapters.Test
  # Send emails from the test process, so tests can assert on them.
  config :plug_app, PlugApp.Auth, background: :inline, rate_limit: [enabled: false]
  config :argon2_elixir, t_cost: 1, m_cost: 8, parallelism: 1
  config :logger, level: :warning
end
