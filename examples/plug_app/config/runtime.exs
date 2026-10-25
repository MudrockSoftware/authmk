import Config

if config_env() == :prod do
  config :plug_app, PlugApp.Auth, base_url: System.fetch_env!("AUTHMK_BASE_URL")
end
