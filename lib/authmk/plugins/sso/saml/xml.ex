defmodule Authmk.Plugins.SSO.SAML.XML do
  @moduledoc false
  # Reads untrusted XML (SAML messages, IdP metadata) with OTP's
  # xmerl_sax_parser into plain maps. Names stay strings (no atoms), and the
  # input is refused when it has a DTD (entities, XXE), a processing
  # instruction, more than @max_depth levels or @max_nodes nodes, or an `ID`
  # used twice (signature wrapping). Comments are dropped, and the text
  # around them joined, as exclusive canonicalization sees it.
  #
  # An element: %{ns:, name:, prefix:, attrs: [%{ns:, prefix:, name:, value:}],
  # declared: [{prefix, uri}], scope: %{prefix => uri}, children: [...]}, where
  # children are elements and text (binaries). No namespace and no prefix
  # are "".

  @max_bytes 1_000_000
  @max_depth 64
  @max_nodes 20_000
  @xml_ns "http://www.w3.org/XML/1998/namespace"

  @doc "`{:ok, root}` or `{:error, :invalid_xml}`."
  def parse(xml) when is_binary(xml) and byte_size(xml) <= @max_bytes do
    state = %{stack: [], pending: [], root: nil, nodes: 0, ids: MapSet.new()}

    options = [
      {:event_fun, &event/3},
      {:event_state, state},
      {:external_entities, :none},
      :skip_external_dtd
    ]

    case :xmerl_sax_parser.stream(xml, options) do
      {:ok, %{root: %{} = root}, _rest} -> {:ok, root}
      _refused -> {:error, :invalid_xml}
    end
  catch
    # Thrown by event/3, or by the parser on bad input.
    _kind, _reason -> {:error, :invalid_xml}
  end

  def parse(_xml), do: {:error, :invalid_xml}

  ## Lookups

  @doc "Direct children of `element` with this namespace and name."
  def children(%{children: children}, ns, name),
    do: for(%{ns: ^ns, name: ^name} = child <- children, do: child)

  @doc "The only such child, or nil when there are none or several."
  def child(element, ns, name) do
    case children(element, ns, name) do
      [child] -> child
      _none_or_many -> nil
    end
  end

  @doc "An attribute without a namespace."
  def attr(%{attrs: attrs}, name),
    do: Enum.find_value(attrs, fn attr -> attr.ns == "" and attr.name == name and attr.value end)

  @doc "The element's text, trimmed."
  def text(%{children: children}),
    do: children |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim()

  ## SAX events

  defp event(:startDocument, _location, state), do: state
  defp event(:endDocument, _location, state), do: state

  defp event({:startPrefixMapping, prefix, uri}, _location, state),
    do: %{state | pending: [{string(prefix), string(uri)} | state.pending]}

  defp event({:endPrefixMapping, _prefix}, _location, state), do: state
  defp event(:startCDATA, _location, state), do: state
  defp event(:endCDATA, _location, state), do: state
  defp event({:comment, _text}, _location, state), do: state

  defp event({:startElement, uri, name, {prefix, _local}, attrs}, _location, state),
    do: start_element(state, string(uri), string(name), string(prefix), attrs)

  defp event({:endElement, _uri, _name, _qname}, _location, state), do: end_element(state)

  defp event({:characters, text}, _location, state), do: add_text(state, text)
  defp event({:ignorableWhitespace, text}, _location, state), do: add_text(state, text)

  # DTDs, entities, processing instructions and anything else: refused.
  defp event(_other, _location, _state), do: throw(:refused)

  defp start_element(%{stack: stack} = state, uri, name, prefix, attrs) do
    if length(stack) >= @max_depth or state.nodes >= @max_nodes, do: throw(:too_large)

    declared = Enum.reverse(state.pending)
    parent_scope = if stack == [], do: %{"xml" => @xml_ns}, else: hd(stack).scope

    element = %{
      ns: uri,
      name: name,
      prefix: prefix,
      attrs: Enum.map(attrs, &attribute/1),
      declared: declared,
      scope: Map.merge(parent_scope, Map.new(declared)),
      children: []
    }

    %{
      state
      | stack: [element | stack],
        pending: [],
        nodes: state.nodes + 1,
        ids: track_id(state.ids, element)
    }
  end

  defp end_element(%{stack: [element | rest]} = state) do
    element = %{element | children: element.children |> Enum.reverse() |> join_text()}

    case rest do
      [] ->
        %{state | stack: [], root: element}

      [parent | above] ->
        %{state | stack: [%{parent | children: [element | parent.children]} | above]}
    end
  end

  # Text outside the root element is only whitespace: drop it.
  defp add_text(%{stack: []} = state, _text), do: state

  defp add_text(%{stack: [element | rest]} = state, text) do
    if state.nodes >= @max_nodes, do: throw(:too_large)
    element = %{element | children: [string(text) | element.children]}
    %{state | stack: [element | rest], nodes: state.nodes + 1}
  end

  defp attribute({uri, prefix, name, value}),
    do: %{ns: string(uri), prefix: string(prefix), name: string(name), value: string(value)}

  # IDs name what a signature covers: each may appear once.
  defp track_id(ids, element) do
    case attr(element, "ID") do
      nil ->
        ids

      id ->
        if MapSet.member?(ids, id), do: throw(:duplicate_id)
        MapSet.put(ids, id)
    end
  end

  # Text split by comments or CDATA becomes one piece, as c14n renders it.
  defp join_text(children) do
    children
    |> Enum.chunk_by(&is_binary/1)
    |> Enum.flat_map(fn
      [text | _more] = texts when is_binary(text) -> [Enum.join(texts)]
      elements -> elements
    end)
  end

  defp string([]), do: ""

  defp string(chars) when is_list(chars) do
    case :unicode.characters_to_binary(chars) do
      binary when is_binary(binary) -> binary
      _invalid -> throw(:invalid_text)
    end
  end

  defp string(binary) when is_binary(binary), do: binary
end
