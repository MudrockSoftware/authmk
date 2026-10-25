import Config

if config_env() == :test do
  # Fast, insecure hashing parameters. Tests only.
  config :argon2_elixir, t_cost: 1, m_cost: 8, parallelism: 1
  config :bcrypt_elixir, log_rounds: 4
  config :logger, level: :warning

  # Every fake provider sign-in signs with a fresh key, so the JWKS is
  # fetched again each time.
  config :authmk, :jwks_refetch_cooldown, 0

  # Each emulation test creates its own database. SQLite by default;
  # AUTHMK_TEST_DB=postgres, mysql or mariadb uses the services in compose.yml.
  test_db = System.get_env("AUTHMK_TEST_DB", "sqlite")
  config :authmk, :test_db, test_db

  connection =
    case test_db do
      "postgres" ->
        [hostname: "localhost", username: "authmk", password: "authmk", pool_size: 2]

      "mysql" ->
        [hostname: "localhost", username: "root", password: "authmk", pool_size: 2]

      "mariadb" ->
        [hostname: "localhost", port: 3307, username: "root", password: "authmk", pool_size: 2]

      "sqlite" ->
        [pool_size: 1]
    end

  config :authmk, Authmk.Test.Repo, [log: false] ++ connection

  # Spans are sent to a test process by the OpenTelemetry tests.
  config :opentelemetry, traces_exporter: :none, processors: [{:otel_simple_processor, %{}}]
end
