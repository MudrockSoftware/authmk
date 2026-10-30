defmodule Mix.Tasks.Compile.AuthmkPages do
  @moduledoc false
  # Builds authmk's SvelteKit apps into priv/ with bun when their sources
  # changed. The built files aren't in git; the Hex package ships them
  # without the sources, so apps using authmk never need bun.
  use Mix.Task.Compiler

  @apps [{"assets/pages", "priv/pages"}, {"licensed/dashboard", "priv/licensed/dashboard"}]

  @impl true
  def run(_args) do
    stale = for {source, output} <- @apps, File.dir?(source), stale?(source, output), do: source
    Enum.each(stale, &build/1)
    if stale == [], do: {:noop, []}, else: {:ok, []}
  end

  defp stale?(source, output) do
    case File.stat(Path.join(output, "index.html"), time: :posix) do
      {:ok, %{mtime: built}} -> Enum.any?(sources(source), &(mtime(&1) > built))
      {:error, _missing} -> true
    end
  end

  defp sources(source) do
    Path.wildcard(Path.join(source, "{src,static,scripts}/**")) ++
      Path.wildcard(
        Path.join(source, "{package.json,bun.lock,bunfig.toml,vite.config.ts,tsconfig.json}")
      )
  end

  defp mtime(path), do: File.stat!(path, time: :posix).mtime

  # `mix build`: rebuilds both, stale or not.
  def build_all, do: for({source, _output} <- @apps, File.dir?(source), do: build(source))

  defp build(source) do
    bun =
      System.find_executable("bun") ||
        Mix.raise("authmk builds #{source} with bun, which isn't installed (https://bun.sh)")

    Mix.shell().info("Building #{source} with bun")
    bun!(bun, ["install", "--frozen-lockfile"], source)
    bun!(bun, ["run", "build"], source)
  end

  defp bun!(bun, args, dir) do
    {_output, status} = System.cmd(bun, args, cd: dir, into: IO.stream(), stderr_to_stdout: true)
    if status != 0, do: Mix.raise("bun #{Enum.join(args, " ")} failed in #{dir}")
  end
end

defmodule Authmk.MixProject do
  use Mix.Project

  alias Mix.Tasks.Compile.AuthmkPages

  @source_url "https://github.com/MudrockSoftware/authmk"
  @homepage_url "https://authmk.com"

  def project do
    [
      app: :authmk,
      version: "1.0.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # Builds the pages and the dashboard (Mix.Tasks.Compile.AuthmkPages above).
      compilers: [:authmk_pages | Mix.compilers()],
      test_paths: ["test", "licensed/test"],
      build_path: build_path(),
      # Tests define auth modules, whose schemas derive protocols.
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      aliases: aliases(),
      # test/support/ is compiled code, not tests.
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      test_coverage: [
        summary: [threshold: 90],
        ignore_modules: [~r/^Authmk\.Test\./, Authmk.EmulationCase]
      ],
      dialyzer: dialyzer(),
      description: "An extensible, plugin-based authentication framework for Elixir.",
      package: package(),
      source_url: @source_url,
      homepage_url: @homepage_url,
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "guides/email-password-and-sessions.md",
          "guides/social-sign-in.md",
          "guides/sign-in-methods.md",
          "guides/organizations-and-access-control.md",
          "guides/phoenix-and-liveview.md",
          "guides/api-clients.md",
          "guides/payments.md",
          "guides/oauth-provider.md",
          "guides/enterprise-sso-and-scim.md",
          "guides/security.md",
          "guides/testing.md",
          "guides/browser-extensions.md",
          "guides/performance.md",
          "guides/migrating-from-phx-gen-auth.md",
          "guides/migrating-from-pow.md",
          "guides/migrating-from-ash-authentication.md",
          "guides/writing-plugins.md",
          "guides/deployment.md",
          "guides/cookies-and-domains.md",
          "guides/stability.md",
          "guides/errors.md",
          "CHANGELOG.md",
          "ROADMAP.md",
          "SECURITY.md"
        ],
        groups_for_extras: [Guides: ~r/guides\//]
      ]
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

  # licensed/ holds the features under the source-available licence (see
  # licensed/LICENSE.md); it builds with the rest.
  defp elixirc_paths(:test), do: ["lib", "licensed/lib", "test/support", "licensed/test/support"]
  defp elixirc_paths(_), do: ["lib", "licensed/lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:plug, "~> 1.18"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:argon2_elixir, "~> 4.1"},
      {:req, "~> 0.5"},
      {:jose, "~> 1.11"},
      {:nimble_totp, "~> 1.0"},
      {:redix, "~> 1.5", optional: true},
      {:bcrypt_elixir, "~> 3.2", optional: true},
      {:igniter, "~> 0.8", optional: true},
      # For Authmk.Plugins.Passkey.
      {:wax_, "~> 0.7", optional: true},
      # For Authmk.Plugins.SIWE.
      {:ex_secp256k1, "~> 0.8", optional: true},
      {:ex_keccak, "~> 0.7", optional: true},
      # Background work as Oban jobs (Authmk.Background).
      {:oban, "~> 2.19", optional: true},
      # Ready-made emails (Authmk.Emails).
      {:swoosh, "~> 1.17", optional: true},
      # LiveView hooks and components (Authmk.LiveView, Authmk.Components).
      {:phoenix_live_view, "~> 1.2", optional: true},
      {:opentelemetry_api, "~> 1.4", optional: true},
      {:opentelemetry_telemetry, "~> 1.1", optional: true},
      {:opentelemetry, "~> 1.5", only: :test},
      {:ecto_sqlite3, "~> 0.22", only: :test},
      {:postgrex, "~> 0.20", only: :test},
      {:myxql, "~> 0.8", only: :test},
      # The installer tests generate Phoenix projects (Igniter.Test.phx_test_project/1).
      {:phx_new, "~> 1.8", only: :test, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      # Phoenix.LiveViewTest, for the LiveView integration's tests.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      # Fetches deps and enables the git pre-commit hook (lint + Dialyzer).
      setup: ["deps.get", &install_git_hooks/1],
      # Rebuilds the pages and the dashboard with bun, then compiles.
      build: [fn _args -> AuthmkPages.build_all() end, "compile"],
      # The package ships the built pages and dashboard: build them first.
      # Only that compiler: a full compile drops the Hex archive from the code path.
      "hex.build": ["compile.authmk_pages", "hex.build"],
      "hex.publish": ["compile.authmk_pages", "hex.publish"],
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
      # lib/ is MIT; licensed/ and priv/licensed/ are under licensed/LICENSE.md.
      licenses: ["MIT", "LicenseRef-Mudrock-Source-Available"],
      links: %{"Website" => @homepage_url, "GitHub" => @source_url},
      files:
        ~w(lib licensed/lib licensed/LICENSE.md priv/pages priv/licensed priv/js guides .formatter.exs
           mix.exs README.md CHANGELOG.md ROADMAP.md SECURITY.md LICENSE)
    ]
  end
end
