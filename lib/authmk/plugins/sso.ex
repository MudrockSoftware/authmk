defmodule Authmk.Plugins.SSO do
  @moduledoc """
  Single sign-on with your customers' identity providers (OpenID Connect):
  each organization signs in with its own Okta, Entra ID, Google Workspace...

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.SSO], ...

  | Method | Path | Session |
  |---|---|---|
  | POST | `/sign-in/sso` | none |
  | GET | `/sso/callback/:provider_id` (or `/sso/callback`) | none |
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
  alias Authmk.Plugins.SSO.{Management, Options, SignIn}

  @impl true
  def init(opts) do
    opts
    |> NimbleOptions.validate!(Options.schema())
    |> Keyword.update!(:default_providers, fn
      providers when is_function(providers, 0) -> providers.()
      providers -> providers
    end)
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
          oidc_config: [type: :text, returned: false, redact: true, input: false]
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
          issuer: [type: :string, required: true],
          domain: [type: :string],
          organization_id: [type: :string],
          oidc_config: [type: :map, required: true]
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
