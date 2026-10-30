defmodule Authmk.Plugins.SSO do
  @moduledoc """
  Single sign-on with your customers' identity providers (OpenID Connect or
  SAML 2.0): each organization signs in with its own Okta, Entra ID, Google
  Workspace...

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.SSO], ...

  | Method | Path | Session |
  |---|---|---|
  | POST | `/sign-in/sso` | none |
  | GET | `/sso/callback/:provider_id` (or `/sso/callback`) | none |
  | POST | `/sso/saml2/acs/:provider_id` | none |
  | GET | `/sso/saml2/finish` | none |
  | GET | `/sso/saml2/metadata/:provider_id` | none |
  | POST | `/sso/register` | required |
  | GET | `/sso/providers` | required |
  | POST | `/sso/delete-provider` | required |
  | POST | `/sso/request-domain-verification` | required |
  | POST | `/sso/verify-domain` | required |

  `POST /sign-in/sso` finds the provider by `provider_id`, `organization_id`,
  or the domain of `email` (or `domain`), and answers with the URL to send
  the user to. Register each provider's callback URL with it:
  `<base URL>/sso/callback/<provider_id>`, or `/sso/callback` for all with
  `shared_redirect_uri: true`.

  Providers are registered with `POST /sso/register` (`provider_id`,
  `issuer`, `domain`, `organization_id`, and `oidc_config` with `client_id`
  and `client_secret`), or listed in `default_providers`. The issuer must
  be an HTTPS URL on a public host, answering OpenID Connect discovery.
  Client secrets are stored encrypted.

  ## SAML 2.0

  Register a SAML provider with `saml_config` instead of `oidc_config`:
  either the identity provider's `metadata` (its XML), or its `entity_id`,
  `sso_url` and `certificates` (PEM). Give its admin this provider's
  metadata, `<base URL>/sso/saml2/metadata/<provider_id>` (that URL is also
  our entity ID), or the assertion consumer service URL,
  `<base URL>/sso/saml2/acs/<provider_id>`.

  Users are sent with an AuthnRequest (HTTP-Redirect binding, signed when
  `saml: [signing_keys: ...]` is set) and come back with a Response (HTTP-POST
  binding), which must:

    * be signed (the Assertion, or the Response) with one of the provider's
      certificates, with RSA or ECDSA and SHA-256 or stronger;
    * answer the request this browser started (`InResponseTo`), unless the
      provider has `allow_idp_initiated: true`;
    * be for this provider (audience, recipient, destination, issuer), and
      within its time limits (`saml: [clock_skew: 120]` seconds);
    * not have been used before: each assertion signs in once.

  Encrypted assertions aren't supported yet. XML is read with OTP's
  `xmerl_sax_parser`, refusing DTDs and entities, and signatures are
  checked with OTP's `public_key`.

  Who the user is comes from the assertion's NameID, and their email and
  name from its attributes. Common attribute names (`email`, `mail`,
  `firstName`, `givenName`, `displayName`, and Microsoft's and the
  standard OIDs) work as they are. Set `mapping` in `saml_config` for
  others: `%{"email" => "...", "name" => "...", "first_name" => "...",
  "last_name" => "...", "id" => "..."}`.

  A provider's domain is proven with a DNS TXT record
  (`/sso/request-domain-verification`, then `/sso/verify-domain`). Until
  then, by default, emails at that domain aren't sent to it, and it can't
  sign in users who already have accounts, only ones it creates: a provider
  can't take over accounts by claiming their emails. With
  `Authmk.Plugins.Organization`, users join the provider's organization.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.SSO.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.Endpoint
  alias Authmk.Plugins.SSO.{Management, Options, SAMLSignIn, SignIn}
  alias Authmk.Plugins.SSO.SAML.Certificates

  @impl true
  def init(opts) do
    opts
    |> NimbleOptions.validate!(Options.schema())
    |> Keyword.update!(:default_providers, &(&1 |> call() |> Enum.map(fn p -> parse_saml(p) end)))
    |> Keyword.update!(:saml, fn saml ->
      Keyword.update!(
        saml,
        :signing_keys,
        &(&1 |> call() |> Enum.map(fn k -> signing_key(k) end))
      )
    end)
  end

  # Secrets from runtime config come as functions.
  defp call(value) when is_function(value, 0), do: value.()
  defp call(value), do: value

  # Bad keys and certificates fail at start, not at sign-in.
  defp signing_key(entry) do
    with {:ok, key} <- Certificates.private_key(entry[:private_key]),
         {:ok, certificate} <- Certificates.parse(entry[:certificate]) do
      %{key: key, certificate: certificate}
    else
      :error ->
        raise ArgumentError,
              "SSO saml signing_keys need an RSA private_key and its certificate (PEM)"
    end
  end

  defp parse_saml(provider) do
    case provider[:saml] do
      nil -> provider
      saml -> Keyword.put(provider, :saml, check_saml(provider[:provider_id], saml))
    end
  end

  defp check_saml(provider_id, saml) do
    certificates = Enum.map(saml[:certificates] || [], &certificate(provider_id, &1))

    if certificates == [] or not is_binary(saml[:entity_id]) or not is_binary(saml[:sso_url]),
      do:
        raise(
          ArgumentError,
          "SSO provider #{provider_id}: saml needs entity_id, sso_url and certificates"
        )

    Keyword.put(saml, :certificates, certificates)
  end

  defp certificate(provider_id, pem) do
    case Certificates.parse(pem) do
      {:ok, certificate} -> certificate
      :error -> raise ArgumentError, "SSO provider #{provider_id}: invalid certificate"
    end
  end

  @impl true
  def schema(_opts) do
    %{
      sso_provider: [
        plural: "sso_providers",
        fields: [
          provider_id: [type: :string, required: true, unique: true, input: false],
          type: [type: :string, required: true, input: false],
          issuer: [type: :string, required: true, input: false],
          domain: [type: :string, index: true, input: false],
          domain_verified: [type: :boolean, required: true, default: false, input: false],
          # Without a foreign key: the organization plugin may not be on.
          organization_id: [type: :string, index: true, input: false],
          user_id: [references: :user, index: true, input: false],
          # JSON, with the client secret encrypted.
          oidc_config: [type: :text, returned: false, redact: true, input: false],
          # JSON: entity_id, sso_url, certificates, mapping, allow_idp_initiated.
          saml_config: [type: :text, returned: false, input: false]
        ]
      ],
      # SAML assertions used, until they expire: each signs in once.
      saml_assertion: [
        plural: "saml_assertions",
        fields: [
          # SHA-256 of the issuer and the assertion ID.
          key: [type: :string, required: true, unique: true, input: false],
          expires_at: [type: :datetime, required: true, index: true, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    provider_id = [provider_id: [type: :string, required: true]]

    [
      endpoint(:sign_in_sso, :post, "/sign-in/sso", {SignIn, :start},
        rate_limit: [window: 10, max: 5],
        params: [
          provider_id: [type: :string],
          organization_id: [type: :string],
          email: [type: :string],
          domain: [type: :string],
          callback_url: [type: :string],
          new_user_callback_url: [type: :string],
          error_callback_url: [type: :string]
        ]
      ),
      endpoint(:sso_callback, :get, "/sso/callback", {SignIn, :callback}, []),
      # The identity provider's page posts here, from its own origin.
      endpoint(:sso_saml_acs, :post, "/sso/saml2/acs/:provider_id", {SAMLSignIn, :acs},
        origin_check: false,
        rate_limit: [window: 10, max: 10]
      ),
      endpoint(:sso_saml_finish, :get, "/sso/saml2/finish", {SAMLSignIn, :finish}, []),
      endpoint(
        :sso_saml_metadata,
        :get,
        "/sso/saml2/metadata/:provider_id",
        {SAMLSignIn, :metadata},
        []
      ),
      endpoint(
        :sso_callback_provider,
        :get,
        "/sso/callback/:provider_id",
        {SignIn, :callback},
        []
      ),
      endpoint(:sso_register, :post, "/sso/register", {Management, :register},
        session: :required,
        params: [
          provider_id: [type: :string, required: true],
          issuer: [type: :string],
          domain: [type: :string],
          organization_id: [type: :string],
          oidc_config: [type: :map],
          saml_config: [type: :map]
        ]
      ),
      endpoint(:sso_providers, :get, "/sso/providers", {Management, :list},
        session: :required,
        params: [organization_id: [type: :string]]
      ),
      endpoint(:sso_delete_provider, :post, "/sso/delete-provider", {Management, :delete},
        session: :required,
        params: provider_id
      ),
      endpoint(
        :sso_request_domain_verification,
        :post,
        "/sso/request-domain-verification",
        {Management, :request_domain_verification},
        session: :required,
        params: provider_id
      ),
      endpoint(:sso_verify_domain, :post, "/sso/verify-domain", {Management, :verify_domain},
        session: :required,
        params: provider_id
      )
    ]
  end

  defp endpoint(name, method, path, handler, opts),
    do: Endpoint.new([name: name, method: method, path: path, handler: handler] ++ opts)
end
