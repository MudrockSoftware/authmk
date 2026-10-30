defmodule Authmk.Plugins.SSO.SAML.Logout do
  @moduledoc false
  # Single logout messages: LogoutRequest and LogoutResponse, built for the
  # identity provider and checked when they come from it. A message coming
  # in must be from the provider (Issuer), for us (Destination, when
  # given), recent (IssueInstant within @max_age, NotOnOrAfter not past),
  # and signed: by the redirect binding, or with an enveloped signature
  # when posted.

  alias Authmk.Plugins.SSO.SAML.{Request, Signature, XML}

  @protocol "urn:oasis:names:tc:SAML:2.0:protocol"
  @assertion "urn:oasis:names:tc:SAML:2.0:assertion"
  @success "urn:oasis:names:tc:SAML:2.0:status:Success"
  @max_age 600

  @doc "A LogoutRequest for the user's IdP session."
  def request_xml(%{id: id, issuer: issuer, destination: destination} = request) do
    session_index =
      if request.session_index,
        do: "<samlp:SessionIndex>#{Request.escape(request.session_index)}</samlp:SessionIndex>",
        else: ""

    format =
      if request.name_id_format,
        do: ~s( Format="#{Request.escape(request.name_id_format)}"),
        else: ""

    ~s(<samlp:LogoutRequest xmlns:samlp="#{@protocol}" xmlns:saml="#{@assertion}" ) <>
      ~s(ID="#{id}" Version="2.0" IssueInstant="#{now()}" Destination="#{Request.escape(destination)}">) <>
      ~s(<saml:Issuer>#{Request.escape(issuer)}</saml:Issuer>) <>
      ~s(<saml:NameID#{format}>#{Request.escape(request.name_id)}</saml:NameID>) <>
      session_index <> "</samlp:LogoutRequest>"
  end

  @doc "A LogoutResponse to the provider's request `in_response_to`."
  def response_xml(%{
        id: id,
        issuer: issuer,
        destination: destination,
        in_response_to: in_response_to
      }) do
    ~s(<samlp:LogoutResponse xmlns:samlp="#{@protocol}" xmlns:saml="#{@assertion}" ) <>
      ~s(ID="#{id}" Version="2.0" IssueInstant="#{now()}" Destination="#{Request.escape(destination)}" ) <>
      ~s(InResponseTo="#{Request.escape(in_response_to)}">) <>
      ~s(<saml:Issuer>#{Request.escape(issuer)}</saml:Issuer>) <>
      ~s(<samlp:Status><samlp:StatusCode Value="#{@success}"/></samlp:Status>) <>
      "</samlp:LogoutResponse>"
  end

  @doc """
  A message from the provider, as `{:ok, :request | :response, fields}`.
  `expected`: `:issuer`, `:destination`, `:certificates`, `:now`,
  `:clock_skew`, and `:signed` (true when the redirect binding's signature
  already checked out; otherwise the message must carry its own).
  """
  def parse(xml, expected) do
    with {:ok, root} <- XML.parse(xml),
         {:ok, kind} <- kind(root),
         :ok <- check(XML.attr(root, "Version") == "2.0", :unsupported_version),
         :ok <- signed(root, expected),
         :ok <- issuer(root, expected),
         :ok <- destination(root, expected),
         :ok <- fresh(root, expected) do
      fields(kind, root)
    end
  end

  defp kind(%{ns: @protocol, name: "LogoutRequest"}), do: {:ok, :request}
  defp kind(%{ns: @protocol, name: "LogoutResponse"}), do: {:ok, :response}
  defp kind(_other), do: {:error, :not_a_logout_message}

  defp signed(_root, %{signed: true}), do: :ok

  defp signed(root, expected) do
    if Signature.signed?(root),
      do: Signature.verify(root, expected.certificates),
      else: {:error, :unsigned}
  end

  defp issuer(root, expected) do
    case XML.child(root, @assertion, "Issuer") do
      %{} = issuer -> check(XML.text(issuer) == expected.issuer, :invalid_issuer)
      nil -> {:error, :invalid_issuer}
    end
  end

  defp destination(root, expected) do
    case XML.attr(root, "Destination") do
      nil -> :ok
      destination -> check(destination == expected.destination, :invalid_destination)
    end
  end

  defp fresh(root, expected) do
    with {:ok, issued} <- time(XML.attr(root, "IssueInstant")),
         :ok <-
           check(
             abs(DateTime.diff(expected.now, issued)) <= @max_age + expected.clock_skew,
             :expired
           ),
         do: not_on_or_after(XML.attr(root, "NotOnOrAfter"), expected)
  end

  defp not_on_or_after(nil, _expected), do: :ok

  defp not_on_or_after(value, expected) do
    with {:ok, until} <- time(value),
         do: check(DateTime.diff(expected.now, until) < expected.clock_skew, :expired)
  end

  defp fields(:request, root) do
    case XML.child(root, @assertion, "NameID") do
      %{} = name_id ->
        session_indexes = root |> XML.children(@protocol, "SessionIndex") |> Enum.map(&XML.text/1)

        {:ok, :request,
         %{id: XML.attr(root, "ID"), name_id: XML.text(name_id), session_indexes: session_indexes}}

      nil ->
        {:error, :invalid_subject}
    end
  end

  defp fields(:response, root) do
    success =
      with %{} = status <- XML.child(root, @protocol, "Status"),
           %{} = code <- XML.child(status, @protocol, "StatusCode") do
        XML.attr(code, "Value") == @success
      end

    {:ok, :response, %{in_response_to: XML.attr(root, "InResponseTo"), success: success == true}}
  end

  defp time(nil), do: {:error, :invalid_time}

  defp time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> {:ok, time}
      {:error, _reason} -> {:error, :invalid_time}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
