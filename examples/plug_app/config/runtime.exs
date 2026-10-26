import Config

# Sign in with Google (and One Tap) when its OAuth client is configured.
# Create one at https://console.cloud.google.com/apis/credentials with the
# callback URL http://localhost:4001/auth/callback/google.
if config_env() != :test and System.get_env("GOOGLE_CLIENT_ID") do
  config :plug_app, PlugApp.Auth,
    social_providers: [
      google: [
        client_id: System.fetch_env!("GOOGLE_CLIENT_ID"),
        client_secret: System.fetch_env!("GOOGLE_CLIENT_SECRET")
      ]
    ]
end

if config_env() == :prod do
  config :plug_app, PlugApp.Auth, base_url: System.fetch_env!("AUTHMK_BASE_URL")
end
