defmodule Authmk.Plugins.SSO.SAML.Response do
  @moduledoc false
  # Checks a SAML Response from an identity provider (HTTP-POST binding)
  # and returns who it vouches for. Everything below must hold:
  #
  #   * it's under the size limit, and safe XML (Authmk.Plugins.SSO.SAML.XML);
  #   * a Response with one Assertion (encrypted ones aren't supported);
  #   * the Assertion is signed, or the Response around it, with the
  #     provider's certificate, and any signature present is valid;
  #   * status Success; issuer, audience, destination and recipient are ours;
  #   * within its time limits (allowing `clock_skew` seconds);
  #   * a bearer subject confirmation that matches the request.
  #
  # Values are read only from the elements that were checked.

  alias Authmk.Plugins.SSO.SAML.{Signature, XML}

  @protocol "urn:oasis:names:tc:SAML:2.0:protocol"
  @assertion "urn:oasis:names:tc:SAML:2.0:assertion"
  @success "urn:oasis:names:tc:SAML:2.0:status:Success"
  @bearer "urn:oasis:names:tc:SAML:2.0:cm:bearer"

  @max_size 256_000

  @doc """
  `{:ok, identity}` or `{:error, reason}`. `expected`: `:issuer`,
  `:certificates`, `:audience`, `:recipient` (the ACS URL), `:now`,
  `:clock_skew`.
  """
  def validate(encoded, expected) when is_binary(encoded) and byte_size(encoded) <= @max_size do
    with {:ok, xml} <- decode(encoded),
         {:ok, response} <- XML.parse(xml),
         :ok <- check(response.ns == @protocol and response.name == "Response", :not_a_response),
         :ok <- check(XML.attr(response, "Version") == "2.0", :unsupported_version),
         :ok <- destination(response, expected),
         :ok <- status(response),
         :ok <- issuer(response, expected, false),
         {:ok, assertion} <- assertion(response),
         :ok <- signatures(response, assertion, expected),
         :ok <- issuer(assertion, expected, true),
         {:ok, expires_at} <- conditions(assertion, expected),
         in_response_to = XML.attr(response, "InResponseTo"),
         {:ok, subject, confirmed_until} <- subject(assertion, expected, in_response_to) do
      {:ok,
       %{
         assertion_id: XML.attr(assertion, "ID"),
         in_response_to: in_response_to,
         name_id: XML.text(subject),
         name_id_format: XML.attr(subject, "Format"),
         attributes: attributes(assertion),
         session_index: session_index(assertion),
         expires_at: earliest(expires_at, confirmed_until)
       }}
    end
  end

  def validate(_encoded, _expected), do: {:error, :too_large}

  defp decode(encoded) do
    case encoded |> String.replace(~r/\s+/, "") |> Base.decode64() do
      {:ok, xml} -> {:ok, xml}
      :error -> {:error, :invalid_encoding}
    end
  end

  # Signed responses must say where they were sent; when they do, it's us.
  defp destination(response, expected) do
    case XML.attr(response, "Destination") do
      nil -> check(not Signature.signed?(response), :invalid_destination)
      destination -> check(destination == expected.recipient, :invalid_destination)
    end
  end

  defp status(response) do
    with %{} = status <- XML.child(response, @protocol, "Status"),
         %{} = code <- XML.child(status, @protocol, "StatusCode"),
         @success <- XML.attr(code, "Value") do
      :ok
    else
      _failed -> {:error, :saml_status}
    end
  end

  # The Response's Issuer is optional; the Assertion's isn't.
  defp issuer(element, expected, required) do
    case XML.children(element, @assertion, "Issuer") do
      [] -> check(not required, :invalid_issuer)
      [issuer] -> check(XML.text(issuer) == expected.issuer, :invalid_issuer)
      _many -> {:error, :invalid_issuer}
    end
  end

  defp assertion(response) do
    cond do
      XML.children(response, @assertion, "EncryptedAssertion") != [] ->
        {:error, :encrypted_assertion}

      assertion = XML.child(response, @assertion, "Assertion") ->
        with :ok <- check(XML.attr(assertion, "Version") == "2.0", :unsupported_version),
             :ok <-
               check(
                 XML.children(assertion, @assertion, "AuthnStatement") != [],
                 :no_authn_statement
               ),
             do: {:ok, assertion}

      true ->
        {:error, :no_assertion}
    end
  end

  # Every signature present must be valid, and one must cover the Assertion.
  defp signatures(response, assertion, expected) do
    signed = Enum.filter([response, assertion], &Signature.signed?/1)

    cond do
      signed == [] ->
        {:error, :unsigned}

      Enum.all?(signed, &(Signature.verify(&1, expected.certificates) == :ok)) ->
        :ok

      true ->
        {:error, :invalid_signature}
    end
  end

  defp conditions(assertion, expected) do
    case XML.children(assertion, @assertion, "Conditions") do
      [conditions] ->
        with :ok <- not_before(XML.attr(conditions, "NotBefore"), expected),
             {:ok, until} <- not_on_or_after(XML.attr(conditions, "NotOnOrAfter"), expected),
             :ok <- audiences(conditions, expected) do
          {:ok, until}
        end

      _none_or_many ->
        {:error, :invalid_conditions}
    end
  end

  # Each AudienceRestriction must name us; at least one must be there.
  defp audiences(conditions, expected) do
    restrictions = XML.children(conditions, @assertion, "AudienceRestriction")

    names_us? = fn restriction ->
      restriction
      |> XML.children(@assertion, "Audience")
      |> Enum.any?(&(XML.text(&1) == expected.audience))
    end

    check(restrictions != [] and Enum.all?(restrictions, names_us?), :invalid_audience)
  end

  defp subject(assertion, expected, in_response_to) do
    with %{} = subject <- XML.child(assertion, @assertion, "Subject"),
         %{} = name_id <- XML.child(subject, @assertion, "NameID"),
         false <- XML.text(name_id) == "" do
      subject
      |> XML.children(@assertion, "SubjectConfirmation")
      |> Enum.find_value(&bearer(&1, expected, in_response_to))
      |> case do
        {:ok, until} -> {:ok, name_id, until}
        nil -> {:error, :invalid_subject_confirmation}
      end
    else
      _missing -> {:error, :invalid_subject}
    end
  end

  # A bearer confirmation for our ACS, still valid, answering our request.
  defp bearer(confirmation, expected, in_response_to) do
    with @bearer <- XML.attr(confirmation, "Method"),
         %{} = data <- XML.child(confirmation, @assertion, "SubjectConfirmationData"),
         true <- XML.attr(data, "Recipient") == expected.recipient,
         true <- XML.attr(data, "InResponseTo") == in_response_to,
         :ok <- not_before(XML.attr(data, "NotBefore"), expected),
         {:ok, until} <- not_on_or_after(XML.attr(data, "NotOnOrAfter"), expected) do
      {:ok, until}
    else
      _no -> nil
    end
  end

  defp not_before(nil, _expected), do: :ok

  defp not_before(value, expected) do
    case parse_time(value) do
      {:ok, time} ->
        check(DateTime.diff(time, expected.now) <= expected.clock_skew, :not_yet_valid)

      :error ->
        {:error, :invalid_time}
    end
  end

  # Required: an assertion valid forever could be replayed forever.
  defp not_on_or_after(nil, _expected), do: {:error, :invalid_time}

  defp not_on_or_after(value, expected) do
    case parse_time(value) do
      {:ok, time} ->
        if DateTime.diff(expected.now, time) < expected.clock_skew,
          do: {:ok, time},
          else: {:error, :expired}

      :error ->
        {:error, :invalid_time}
    end
  end

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> {:ok, time}
      {:error, _reason} -> :error
    end
  end

  defp attributes(assertion) do
    for statement <- XML.children(assertion, @assertion, "AttributeStatement"),
        attribute <- XML.children(statement, @assertion, "Attribute"),
        name = XML.attr(attribute, "Name"),
        is_binary(name),
        reduce: %{} do
      acc ->
        values = attribute |> XML.children(@assertion, "AttributeValue") |> Enum.map(&XML.text/1)
        Map.update(acc, name, values, &(&1 ++ values))
    end
  end

  defp session_index(assertion) do
    case XML.children(assertion, @assertion, "AuthnStatement") do
      [statement | _more] -> XML.attr(statement, "SessionIndex")
      [] -> nil
    end
  end

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
