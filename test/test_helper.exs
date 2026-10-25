# Fuzz tests (test/fuzz/, tagged :fuzz) only run via `mix fuzz`.
if runs = System.get_env("FUZZ_RUNS") do
  Application.put_env(:stream_data, :max_runs, String.to_integer(runs))
end

ExUnit.start(exclude: [:fuzz])
