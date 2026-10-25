defmodule Authmk.SchemaCheck do
  @moduledoc """
  Checks that the database has every table and column the schema needs.

  With `advanced: [validate_schema: true]` it runs when the auth module
  starts, so a missing migration fails at boot instead of on the first
  request. Each model costs one `SELECT ... LIMIT 0`.
  """

  import Ecto.Query, only: [from: 2]

  alias Authmk.Config

  @doc "`:ok`, or `{:error, message}` naming each model whose table or columns are missing."
  @spec run(Config.t()) :: :ok | {:error, String.t()}
  def run(%Config{repo: repo, schema: schema}) do
    problems =
      for {_key, model} <- Enum.sort(schema.models), message = problem(repo, model), do: message

    case problems do
      [] ->
        :ok

      problems ->
        {:error,
         Enum.join(problems, "\n") <> "\nRun `mix authmk.gen.migration` and `mix ecto.migrate`."}
    end
  end

  # Selecting every field reads every column, so any missing one fails here.
  defp problem(repo, model) do
    _rows = repo.all(from(record in model.module, limit: 0))
    nil
  rescue
    error ->
      "table #{model.table} (#{inspect(model.module)}) doesn't match: #{Exception.message(error)}"
  end
end
