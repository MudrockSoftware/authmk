defmodule Authmk.Plugins.SSO.SAML.Profile do
  @moduledoc false
  # Who an assertion is about, in the shape Authmk.Plugins.SSO.Users takes:
  # the NameID (or the attribute `mapping["id"]` names) identifies them;
  # email and name come from attributes, by the provider's mapping or the
  # names identity providers commonly use.

  @email ~w(email mail emailAddress
            http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress
            urn:oid:0.9.2342.19200300.100.1.3)
  @name ~w(name displayName
           http://schemas.microsoft.com/identity/claims/displayname
           urn:oid:2.16.840.1.113730.3.1.241)
  @first_name ~w(firstName givenName given_name
                 http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname
                 urn:oid:2.5.4.42)
  @last_name ~w(lastName surname sn family_name
                http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname
                urn:oid:2.5.4.4)

  @email_format "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"

  @doc "The user info, and the profile `resolve_user` sees."
  def from_identity(identity, mapping) do
    attributes = identity["attributes"]

    info = %{
      id: first(attributes, mapping["id"], []) || identity["name_id"],
      email: first(attributes, mapping["email"], @email) || email_name_id(identity),
      name: name(attributes, mapping),
      image: nil,
      # Whether the domain is the provider's own decides this, in Users.
      email_verified: false
    }

    profile = %{
      "name_id" => identity["name_id"],
      "name_id_format" => identity["name_id_format"],
      "attributes" => attributes
    }

    {info, profile}
  end

  defp name(attributes, mapping) do
    first(attributes, mapping["name"], @name) ||
      case {first(attributes, mapping["first_name"], @first_name),
            first(attributes, mapping["last_name"], @last_name)} do
        {nil, nil} -> nil
        {first, last} -> [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      end
  end

  # The mapped attribute, or else the first common name that has a value.
  defp first(attributes, mapped, _common) when is_binary(mapped), do: value(attributes, mapped)
  defp first(attributes, nil, common), do: Enum.find_value(common, &value(attributes, &1))

  defp value(attributes, name) do
    case attributes[name] do
      [value | _more] when value != "" -> value
      _missing -> nil
    end
  end

  defp email_name_id(%{"name_id_format" => @email_format, "name_id" => name_id}), do: name_id
  defp email_name_id(_identity), do: nil
end
