defmodule Authmk.Plugins.SSO.Options do
  @moduledoc false

  def schema do
    NimbleOptions.new!(
      default_providers: [
        type: {:or, [{:list, :keyword_list}, {:fun, 0}]},
        default: [],
        doc:
          "Providers from config, used before any in the database: `[provider_id:, issuer:, client_id:, client_secret:, domain:]`, plus `discovery_url:`, `scopes:`, `organization_id:`. Their domains count as verified. A function of no arguments is called when the auth module starts, for secrets from runtime config."
      ],
      shared_redirect_uri: [
        type: :boolean,
        default: false,
        doc:
          "Send every provider to `/sso/callback` instead of `/sso/callback/<provider_id>`, for identity providers where one redirect URI is registered for all."
      ],
      domain_verification: [
        type: :boolean,
        default: true,
        doc:
          "Only route emails to a provider, and only link existing users by email, once its domain is verified with a DNS TXT record."
      ],
      disable_sign_up: [
        type: :boolean,
        default: false,
        doc: "Only existing users may sign in with SSO."
      ],
      organization_role: [
        type: :string,
        default: "member",
        doc:
          "Role of users added to a provider's organization (with `Authmk.Plugins.Organization`)."
      ],
      resolve_user: [
        type: {:fun, 3},
        doc:
          "`fn profile, provider, ctx -> {:ok, user} | {:error, error} | :default end`: pick the user to sign in yourself, like by an employee id; `:default` goes on as usual."
      ],
      can_manage: [
        type: {:fun, 3},
        doc:
          "`fn action, organization_id, ctx -> boolean end` for `:register`, `:read` and `:delete`, when a provider belongs to an organization. Without it, only the user who registered a provider manages it, and none can be registered for organizations."
      ],
      resolve_host: [
        type: {:fun, 1},
        doc:
          "`fn host -> {:ok, [ip_address]} | :error end`: how issuer hosts are resolved before authmk fetches their discovery document (DNS by default). Private network addresses are refused either way."
      ],
      resolve_txt: [
        type: {:fun, 1},
        doc:
          "`fn name -> {:ok, [value]} | :error end`: DNS TXT lookups for domain verification (DNS by default)."
      ]
    )
  end
end
