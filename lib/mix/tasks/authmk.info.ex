defmodule Mix.Tasks.Authmk.Info do
  @shortdoc "Shows the auth module's setup and checks it"

  @moduledoc """
  Shows authmk's version, the auth module's repo, plugins, tables and
  endpoints, and checks that migrations are up to date and the runtime
  config (including the secret) is valid.

      mix authmk.info
      mix authmk.info --auth MyApp.Auth
      mix authmk.info --snapshot-path priv/repo/authmk/my_app_auth.json

  Exits with an error when a check fails, so it also works in CI.
  """

  use Mix.Task

  alias Authmk.Migration
  alias Authmk.Migration.Snapshot

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [auth: :string, snapshot_path: :string])
    Mix.Task.run("compile", [])
    Mix.Task.run("app.config", [])

    auth = Mix.Authmk.auth_module(opts[:auth])
    compile = auth.__authmk__(:compile_options)
    repo = compile[:repo]

    tables =
      auth.__authmk__(:schema).models |> Map.values() |> Enum.map(& &1.table) |> Enum.sort()

    snapshot = Snapshot.read(opts[:snapshot_path] || Mix.Authmk.snapshot_path(repo, auth))
    migrations = check_migrations(auth, snapshot)
    config = check_config(auth)

    info("""
    authmk #{Application.spec(:authmk, :vsn)}
    Auth module:  #{inspect(auth)}
    Repo:         #{inspect(repo)} (#{Migration.adapter(repo)})
    Plugins:      #{plugins(compile[:plugins])}
    Tables:       #{Enum.join(tables, ", ")}
    Migrations:   #{status(migrations)}
    Config:       #{status(config)}\
    """)

    case config do
      {:ok, config} ->
        info("\nEndpoints:\n" <> Enum.map_join(config.endpoints, "\n", &endpoint_line/1))

      {:error, _message} ->
        :ok
    end

    if elem(migrations, 0) == :error or elem(config, 0) == :error do
      Mix.raise("authmk checks failed")
    end
  end

  defp check_migrations(auth, snapshot) do
    case Migration.changes(auth, snapshot) do
      [] -> {:ok, "up to date"}
      ops -> {:error, "#{length(ops)} change(s) not migrated. Run `mix authmk.gen.migration`"}
    end
  end

  # Builds the runtime config like startup does, without starting anything.
  defp check_config(auth) do
    {:ok, Authmk.Config.load(auth)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp status({:ok, %Authmk.Config{}}), do: "ok"
  defp status({_result, message}), do: message

  defp plugins([]), do: "none"

  defp plugins(plugins),
    do: Enum.map_join(plugins, ", ", fn {plugin, _opts} -> inspect(plugin) end)

  defp endpoint_line(endpoint) do
    method = endpoint.method |> Atom.to_string() |> String.upcase() |> String.pad_trailing(5)
    "  #{method}#{endpoint.path}"
  end

  defp info(text), do: Mix.shell().info(text)
end
