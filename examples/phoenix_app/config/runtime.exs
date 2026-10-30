import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/phoenix_app start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :phoenix_app, PhoenixAppWeb.Endpoint, server: true
end

config :phoenix_app, PhoenixAppWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Social sign-in for the providers whose apps are configured. Create them at
# https://github.com/settings/developers and
# https://console.cloud.google.com/apis/credentials, with the callback URLs
# http://localhost:4000/auth/callback/github and .../callback/google. Google
# also gives One Tap.
if config_env() != :test do
  providers =
    for {name, prefix} <- [github: "GITHUB", google: "GOOGLE"],
        client_id = System.get_env("#{prefix}_CLIENT_ID"),
        do:
          {name,
           [client_id: client_id, client_secret: System.fetch_env!("#{prefix}_CLIENT_SECRET")]}

  config :phoenix_app, PhoenixApp.Auth, social_providers: providers
end

# Social sign-in on previews and localhost through production's callback
# URL (Authmk.Plugins.OAuthProxy): set OAUTH_PROXY_URL to production's base
# URL and OAUTH_PROXY_SECRET to a secret every deployment shares, production
# included, and add the previews to trusted_origins there.
if config_env() != :test and System.get_env("OAUTH_PROXY_URL") do
  config :phoenix_app, :oauth_proxy,
    production_url: System.fetch_env!("OAUTH_PROXY_URL"),
    secret: System.fetch_env!("OAUTH_PROXY_SECRET")
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :phoenix_app, PhoenixAppWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/phoenix_app_web/router\.ex$"E,
        ~r"lib/phoenix_app_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/phoenix_app/phoenix_app.db
      """

  config :phoenix_app, PhoenixApp.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :phoenix_app, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :phoenix_app, PhoenixAppWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  base_url = System.fetch_env!("AUTHMK_BASE_URL")
  config :phoenix_app, PhoenixApp.Auth, base_url: base_url

  # Without OAUTH_PROXY_URL, this is production.
  if !System.get_env("OAUTH_PROXY_URL") do
    config :phoenix_app, :oauth_proxy,
      production_url: base_url,
      secret: System.fetch_env!("OAUTH_PROXY_SECRET")
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :phoenix_app, PhoenixAppWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :phoenix_app, PhoenixAppWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :phoenix_app, PhoenixApp.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
