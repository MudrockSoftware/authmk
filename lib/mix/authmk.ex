defmodule Mix.Authmk do
  @moduledoc false
  # Helpers shared by authmk's mix tasks.

  @doc "The auth module named on the command line, or the app's only one."
  def auth_module(name) do
    case name do
      nil -> find_auth_module()
      name -> Code.ensure_loaded!(Module.concat([name]))
    end
  end

  defp find_auth_module do
    app = Mix.Project.config()[:app]
    _ = Application.load(app)
    modules = Application.spec(app, :modules) || []

    case Enum.filter(modules, &auth_module?/1) do
      [auth] -> auth
      [] -> Mix.raise("No auth module found. Define one with `use Authmk`.")
      many -> Mix.raise("Found several auth modules: #{inspect(many)}. Pick one with --auth.")
    end
  end

  defp auth_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__authmk__, 1)
  end

  def snapshot_path(repo, auth) do
    file = auth |> inspect() |> Macro.underscore() |> String.replace("/", "_")
    Path.join([repo_priv(repo), "authmk", file <> ".json"])
  end

  # Same default as Ecto: priv/<repo name>, relative to the project root.
  def repo_priv(repo) do
    repo.config()[:priv] || "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}"
  end
end
