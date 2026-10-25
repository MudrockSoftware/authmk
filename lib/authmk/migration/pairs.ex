defmodule Authmk.Migration.Pairs do
  @moduledoc false
  # Pairs things that disappeared with things that appeared, when `same?`
  # says they match. Each one is used once; the first match wins.

  @spec match([{String.t(), term()}], [{String.t(), term()}], (term(), term() -> boolean())) ::
          [{String.t(), String.t(), term()}]
  def match(gone, added, same?) do
    {pairs, _unmatched} = Enum.reduce(gone, {[], added}, &pair(&1, &2, same?))
    Enum.reverse(pairs)
  end

  defp pair({old_name, old}, {pairs, added}, same?) do
    case Enum.find(added, fn {_name, new} -> same?.(old, new) end) do
      nil -> {pairs, added}
      {new_name, _new} = match -> {[{old_name, new_name, old} | pairs], List.delete(added, match)}
    end
  end
end
