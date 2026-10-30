defmodule Authmk.Plugins.SSO.SAMLConfig do
  @moduledoc false
  # A SAML provider's settings: from registration params (checked here),
  # from config (certificates already parsed by the plugin's init), or from
  # the JSON stored in `saml_config`. In use, it's a map with `entity_id`,
  # `sso_url`, `certificates` (parsed), `mapping` and `allow_idp_initiated`.

  alias Authmk.{Error, URL}
  alias Authmk.Plugins.SSO.SAML.{Certificates, Metadata}

  @mapping_keys ~w(id email name first_name last_name)
  @max_certificates 10

  def entity_id(ctx, provider),
    do: URL.endpoint(ctx, "/sso/saml2/metadata/" <> provider.provider_id)

  def acs_url(ctx, provider), do: URL.endpoint(ctx, "/sso/saml2/acs/" <> provider.provider_id)

  @doc "Checks registration params; `{:ok, json_map}` to store, or `{:error, error}`."
  def from_params(params) do
    with {:ok, idp} <- idp(params),
         :ok <- check(https?(idp.sso_url), "sso_url must be an HTTPS URL"),
         :ok <- check(valid_entity_id?(idp.entity_id), "entity_id is missing or too long"),
         {:ok, certificates} <- certificates(idp.certificates),
         {:ok, mapping} <- mapping(params["mapping"]),
         :ok <-
           check(
             params["allow_idp_initiated"] in [nil, true, false],
             "allow_idp_initiated must be true or false"
           ) do
      {:ok,
       %{
         "entity_id" => idp.entity_id,
         "sso_url" => idp.sso_url,
         "certificates" => Enum.map(certificates, &Certificates.base64/1),
         "mapping" => mapping,
         "allow_idp_initiated" => params["allow_idp_initiated"] == true
       }}
    end
  end

  # The identity provider's metadata, or its details one by one.
  defp idp(%{"metadata" => xml}) when is_binary(xml) do
    case Metadata.identity_provider(xml) do
      {:ok, idp} -> {:ok, idp}
      {:error, description} -> check(false, description)
    end
  end

  defp idp(params) do
    certificates =
      case params do
        %{"certificates" => list} when is_list(list) -> list
        %{"certificate" => pem} when is_binary(pem) -> [pem]
        _none -> []
      end

    {:ok,
     %{entity_id: params["entity_id"], sso_url: params["sso_url"], certificates: certificates}}
  end

  defp certificates(texts) when texts != [] and length(texts) <= @max_certificates do
    parsed = Enum.map(texts, &Certificates.parse/1)

    if Enum.all?(parsed, &match?({:ok, _certificate}, &1)),
      do: {:ok, Enum.map(parsed, fn {:ok, certificate} -> certificate end)},
      else: check(false, "certificates must be X.509 certificates with RSA or EC keys")
  end

  defp certificates(_texts),
    do: check(false, "Give 1 to #{@max_certificates} signing certificates")

  defp mapping(nil), do: {:ok, %{}}

  defp mapping(mapping) when is_map(mapping) do
    valid? =
      Enum.all?(mapping, fn {key, value} ->
        key in @mapping_keys and is_binary(value) and byte_size(value) in 1..256
      end)

    if valid?,
      do: {:ok, mapping},
      else:
        check(false, "mapping keys are #{Enum.join(@mapping_keys, ", ")}, with attribute names")
  end

  defp mapping(_mapping), do: check(false, "mapping must be an object")

  @doc "From `default_providers` (certificates parsed at start)."
  def from_config(saml) do
    %{
      entity_id: saml[:entity_id],
      sso_url: saml[:sso_url],
      certificates: saml[:certificates],
      mapping: Map.new(saml[:mapping] || %{}, fn {key, value} -> {to_string(key), value} end),
      allow_idp_initiated: saml[:allow_idp_initiated] == true
    }
  end

  @doc "From the stored JSON."
  def from_json(json) do
    saml = JSON.decode!(json)

    %{
      entity_id: saml["entity_id"],
      sso_url: saml["sso_url"],
      certificates:
        for(
          text <- saml["certificates"],
          {:ok, certificate} <- [Certificates.parse(text)],
          do: certificate
        ),
      mapping: saml["mapping"] || %{},
      allow_idp_initiated: saml["allow_idp_initiated"] == true
    }
  end

  defp https?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme == "https" and uri.host not in [nil, ""]
  end

  defp https?(_url), do: false

  defp valid_entity_id?(id), do: is_binary(id) and byte_size(id) in 1..1024

  defp check(true, _description), do: :ok

  defp check(false, description),
    do: {:error, Error.custom(:invalid_sso_provider, 400, description)}
end
