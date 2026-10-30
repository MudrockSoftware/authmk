defmodule Authmk.LogTest do
  # Authmk.Log promises that every log message carries `domain: [:authmk]`,
  # so Logger filters catch them all. That holds while nothing else logs:
  # this reads the source for direct Logger and :logger calls.
  use ExUnit.Case, async: true

  @allowed ["lib/authmk/log.ex"]

  test "everything logs through Authmk.Log" do
    direct =
      for path <- Path.wildcard("lib/**/*.ex") ++ Path.wildcard("licensed/lib/**/*.ex"),
          path not in @allowed,
          line <- logger_calls(path),
          do: "#{path}:#{line}"

    assert direct == [], "Use Authmk.Log instead:\n" <> Enum.join(direct, "\n")
  end

  defp logger_calls(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()
    {_ast, lines} = Macro.prewalk(ast, [], &collect/2)
    lines
  end

  defp collect({{:., meta, [{:__aliases__, _, [:Logger]}, _fun]}, _, _} = node, lines),
    do: {node, [meta[:line] | lines]}

  defp collect({{:., meta, [:logger, _fun]}, _, _} = node, lines),
    do: {node, [meta[:line] | lines]}

  defp collect({:require, meta, [{:__aliases__, _, [:Logger]} | _]} = node, lines),
    do: {node, [meta[:line] | lines]}

  defp collect(node, lines), do: {node, lines}
end
