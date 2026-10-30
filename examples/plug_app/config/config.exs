import Config

config :plug_app, PlugApp.Auth,
  base_url: "http://localhost:4001",
  # The mobile app's deep links (see Authmk.Plugins.OneTimeToken's deep_links).
  trusted_origins: ["plugapp://"],
  # Browser apps on trusted origins may read authmk's answers (CORS).
  cors: [trusted_origins: true]

config :plug_app, ecto_repos: [PlugApp.Repo]

config :plug_app, PlugApp.Repo, database: Path.expand("../plug_app_#{config_env()}.db", __DIR__)

config :plug_app, port: 4001

config :plug_app, PlugApp.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
