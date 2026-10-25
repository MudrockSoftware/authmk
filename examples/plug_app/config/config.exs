import Config

config :plug_app, ecto_repos: [PlugApp.Repo]

config :plug_app, PlugApp.Repo, database: Path.expand("../plug_app_#{config_env()}.db", __DIR__)

config :plug_app, port: 4001

if config_env() == :test do
  config :plug_app, PlugApp.Repo, pool: Ecto.Adapters.SQL.Sandbox, pool_size: 5
  config :plug_app, server: false
  config :logger, level: :warning
end
