defmodule Authmk.ErrorReferenceTest do
  # guides/errors.md promises to list every error code. This reads authmk's
  # source the way a reviewer would: every `@errors` map and every
  # `Error.custom/3,4` call with a literal code and status.
  use ExUnit.Case, async: true

  @guide File.read!("guides/errors.md")

  test "the error reference lists every code with its status and message" do
    missing =
      for path <- Path.wildcard("lib/**/*.ex"),
          {code, status, message} <- errors_in(path),
          not documented?(code, status, message),
          do: "#{path}: #{code} #{status} #{message}"

    assert missing == [], "Add these to guides/errors.md:\n" <> Enum.join(missing, "\n")
  end

  test "every core code is documented" do
    for {code, {status, message}} <- Authmk.Error.codes() do
      assert documented?(code, status, message), "#{code} is missing from guides/errors.md"
    end
  end

  defp documented?(code, status, message) do
    row = "| `#{code}` | #{status} | "

    @guide
    |> String.split("\n")
    |> Enum.any?(&(String.starts_with?(&1, row) and (message == nil or &1 =~ message)))
  end

  defp errors_in(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()
    {_ast, found} = Macro.prewalk(ast, [], &collect/2)
    found
  end

  defp collect({:@, _, [{:errors, _, [{:%{}, _, pairs}]}]} = node, found),
    do: {node, for({code, {status, message}} <- pairs, do: {code, status, message}) ++ found}

  defp collect(
         {{:., _, [{:__aliases__, _, alias}, :custom]}, _, [code, status, message | _]} = node,
         found
       )
       when alias in [[:Error], [:Authmk, :Error]] and is_atom(code) and is_integer(status),
       do: {node, [{code, status, if(is_binary(message), do: message)} | found]}

  defp collect(node, found), do: {node, found}
end
