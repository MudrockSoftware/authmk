import Config

# This server is its own production for social sign-in, unless
# OAUTH_PROXY_URL says otherwise (config/runtime.exs).
config :plug_app, :oauth_proxy,
  production_url: "http://localhost:4001",
  secret: "dev-only OAuth proxy secret, replace it in production"

config :plug_app, PlugApp.Auth, secret: "Z4guQURfsMNwwwPwuuN0Q3N3Q6ZfYciO2-fUw3QlK_A"
