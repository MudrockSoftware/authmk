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

# Social sign-in on previews and localhost through production's callback
# URL (Authmk.Plugins.OAuthProxy): set OAUTH_PROXY_URL to production's base
# URL and OAUTH_PROXY_SECRET to a secret every deployment shares, production
# included, and add the previews to trusted_origins there.
if config_env() != :test and System.get_env("OAUTH_PROXY_URL") do
  config :plug_app, :oauth_proxy,
    production_url: System.fetch_env!("OAUTH_PROXY_URL"),
    secret: System.fetch_env!("OAUTH_PROXY_SECRET")
end

if config_env() == :prod do
  base_url = System.fetch_env!("AUTHMK_BASE_URL")
  config :plug_app, PlugApp.Auth, base_url: base_url

  # Without OAUTH_PROXY_URL, this is production.
  if !System.get_env("OAUTH_PROXY_URL") do
    config :plug_app, :oauth_proxy,
      production_url: base_url,
      secret: System.fetch_env!("OAUTH_PROXY_SECRET")
  end
end
