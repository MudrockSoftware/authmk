defmodule Authmk.MixProject do
  use Mix.Project

  @source_url "https://github.com/MudrockSoftware/authmk"
  @homepage_url "https://authmk.com"

  def project do
    [
      app: :authmk,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      build_path: build_path(),
      # Tests define auth modules, whose schemas derive protocols.
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [
        summary: [threshold: 90],
        ignore_modules: [~r/^Authmk\.Test\./, Authmk.EmulationCase]
      ],
      dialyzer: dialyzer(),
      description:
        "An extensible, plugin-based authentication framework for Elixir, inspired by Better Auth.",
      package: package(),
      source_url: @source_url,
      homepage_url: @homepage_url,
      docs: [main: "readme", extras: ["README.md", "ROADMAP.md"]]
    ]
  end

  def cli do
    [preferred_envs: [coverage: :test, fuzz: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # The test repo's adapter is compiled in, so each test database
  # (AUTHMK_TEST_DB) gets its own build.
  defp build_path do
    case System.get_env("AUTHMK_TEST_DB") do
      db when db in ["postgres", "mysql", "mariadb"] -> "_build/" <> db
      _sqlite -> "_build"
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:plug, "~> 1.18"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:argon2_elixir, "~> 4.1"},
      {:redix, "~> 1.5", optional: true},
      {:bcrypt_elixir, "~> 3.2", optional: true},
      {:ecto_sqlite3, "~> 0.22", only: :test},
      {:postgrex, "~> 0.20", only: :test},
      {:myxql, "~> 0.8", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      # Fetches deps and enables the git pre-commit hook (lint + Dialyzer).
      setup: ["deps.get", &install_git_hooks/1],
      # As CI: fails under the threshold in test_coverage; HTML in cover/.
      coverage: ["test --cover"],
      # Only the fuzz tests (test/fuzz/), FUZZ_RUNS times each.
      fuzz: &fuzz/1,
      lint: [
        "format",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "xref graph --format cycles --fail-above 0",
        "dialyzer"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "_build/plts",
      plt_core_path: "_build/plts",
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :extra_return, :missing_return, :unknown, :unmatched_returns]
    ]
  end

  defp install_git_hooks(_args) do
    if File.dir?(".git") do
      Mix.shell().cmd("git config core.hooksPath .githooks")
      Mix.shell().info("Git hooks enabled (.githooks/pre-commit).")
    else
      Mix.shell().info("Not a git repository; skipping git hook setup.")
    end
  end

  defp fuzz(args) do
    if Path.wildcard("test/fuzz/**/*_test.exs") == [] do
      Mix.shell().info("No fuzz tests in test/fuzz/ yet.")
    else
      System.put_env("FUZZ_RUNS", System.get_env("FUZZ_RUNS", "1000"))
      Mix.Task.run("test", ["test/fuzz", "--only", "fuzz" | args])
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Website" => @homepage_url, "GitHub" => @source_url}
    ]
  end
end
