defmodule Authmk.Plugins.SSO.SAML.C14N do
  @moduledoc false
  # Exclusive XML canonicalization without comments
  # (http://www.w3.org/2001/10/xml-exc-c14n#), over elements from
  # Authmk.Plugins.SSO.SAML.XML: the bytes a signature covers.
  #
  # An element declares the namespaces it, or its attributes, use (and
  # those in `inclusive`, the InclusiveNamespaces PrefixList), unless an
  # element above it in the output already declared the same one.
  # Declarations come first, sorted by prefix; attributes follow, sorted by
  # namespace URI, then name.

  @doc "The canonical form of `element`. `inclusive`: prefixes, `\"\"` for the default."
  def canonicalize(element, inclusive \\ []),
    do: element |> render(%{}, inclusive) |> IO.iodata_to_binary()

  defp render(text, _rendered, _inclusive) when is_binary(text), do: escape_text(text)

  defp render(element, rendered, inclusive) do
    declarations = declarations(element, rendered, inclusive)
    rendered = Enum.into(declarations, rendered)
    name = qualified(element.prefix, element.name)

    [
      "<",
      name,
      Enum.map(declarations, &declaration/1),
      element.attrs |> Enum.sort_by(&{&1.ns, &1.name}) |> Enum.map(&attribute/1),
      ">",
      Enum.map(element.children, &render(&1, rendered, inclusive)),
      "</",
      name,
      ">"
    ]
  end

  # Namespaces the element uses, which the output above doesn't declare yet.
  defp declarations(element, rendered, inclusive) do
    used = [element.prefix | for(%{prefix: prefix} <- element.attrs, prefix != "", do: prefix)]

    included = Enum.filter(inclusive, &Map.has_key?(element.scope, &1))

    (used ++ included)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "xml"))
    |> Enum.map(&{&1, Map.get(element.scope, &1, "")})
    |> Enum.reject(fn {prefix, uri} -> already_declared?(rendered, prefix, uri) end)
    |> Enum.sort()
  end

  # An empty default namespace needs declaring only to undo a non-empty one.
  defp already_declared?(rendered, "", ""), do: Map.get(rendered, "", "") == ""
  defp already_declared?(rendered, prefix, uri), do: Map.get(rendered, prefix) == uri

  defp declaration({"", uri}), do: [~s( xmlns="), escape_attribute(uri), ~s(")]
  defp declaration({prefix, uri}), do: [" xmlns:", prefix, ~s(="), escape_attribute(uri), ~s(")]

  defp attribute(%{prefix: prefix, name: name, value: value}),
    do: [" ", qualified(prefix, name), ~s(="), escape_attribute(value), ~s(")]

  defp qualified("", name), do: name
  defp qualified(prefix, name), do: [prefix, ":", name]

  defp escape_text(text) do
    for <<char <- text>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?\r -> "&#xD;"
        char -> <<char>>
      end
    end
  end

  defp escape_attribute(value) do
    for <<char <- value>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?" -> "&quot;"
        ?\t -> "&#x9;"
        ?\n -> "&#xA;"
        ?\r -> "&#xD;"
        char -> <<char>>
      end
    end
  end
end
