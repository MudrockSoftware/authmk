# Fuzz tests (test/fuzz/, tagged :fuzz) only run via `mix fuzz`.
if runs = System.get_env("FUZZ_RUNS") do
  Application.put_env(:stream_data, :max_runs, String.to_integer(runs))
end

# Configured the way apps do it: through the environment.
System.put_env(
  "AUTHMK_SECRET",
  "test-secret-" <> Base.url_encode64(:crypto.strong_rand_bytes(32))
)

# Tests against real services run when they are configured (see compose.yml).
excluded =
  [:fuzz] ++
    if(System.get_env("REDIS_URL"), do: [], else: [:redis]) ++
    if(System.get_env("AUTHMK_TEST_DB", "sqlite") == "sqlite",
      do: [:server_database],
      else: [:sqlite]
    )

# Migration tests run generated migration files up and down, which loads
# each file again.
Code.put_compiler_option(:ignore_module_conflict, true)

ExUnit.start(exclude: excluded)
