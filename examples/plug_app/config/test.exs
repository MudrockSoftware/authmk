import Config

config :argon2_elixir, t_cost: 1, m_cost: 8

config :plug_app, PlugApp.Auth,
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
