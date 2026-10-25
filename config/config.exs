import Config

if config_env() == :test do
  # Fast, insecure hashing parameters. Tests only.
  config :argon2_elixir, t_cost: 1, m_cost: 8, parallelism: 1
  config :logger, level: :warning

  # Each emulation test starts its own instance on a new database file.
  config :authmk, Authmk.Test.Repo, pool_size: 1, log: false
end
