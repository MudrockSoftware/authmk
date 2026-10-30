defmodule Authmk.Plugins.OAuthProvider.Options do
  @moduledoc false

  @day 24 * 60 * 60

  def schema do
    NimbleOptions.new!(
      login_page: [
        type: :string,
        required: true,
        doc:
          "Your sign-in page. Sign-ins for apps are sent there with `client_id` and `oauth_query`; after signing in, post `oauth_query` to `/oauth2/continue`."
      ],
      consent_page: [
        type: :string,
        required: true,
        doc:
          "Your consent page, sent `client_id`, `scope` and `oauth_query`; it posts the user's answer to `/oauth2/consent`."
      ],
      scopes: [
        type: {:list, :string},
        default: ["openid", "profile", "email", "offline_access"],
        doc: "Scopes clients may ask for."
      ],
      logout_page: [
        type: :string,
        doc:
          "Your page asking users to confirm signing out, for `/oauth2/end-session` requests that can't prove they come from the user's session. It gets `client_id` and `logout_query`, and posts `logout_query` to `/oauth2/end-session/confirm`."
      ],
      resources: [
        type: {:or, [{:list, :string}, {:fun, 0}]},
        default: [],
        doc:
          "APIs clients may ask tokens for, with the `resource` parameter (RFC 8707). Their tokens are JWTs (RFC 9068) with the resource as audience, which the API can check on its own with the JWKS. A function of no arguments is called when the auth module starts, for URLs from runtime config."
      ],
      pairwise_secret: [
        type: :string,
        doc:
          "Enables pairwise subject identifiers: clients registered with `subject_type: \"pairwise\"` see a different `sub` for the same user than other sites, so they can't link users. At least 32 bytes; changing it changes every pairwise `sub`."
      ],
      issuer: [type: :string, doc: "The issuer identifier. Default: the base URL and path."],
      code_expires_in: [type: :pos_integer, default: 60, doc: "Seconds."],
      access_token_expires_in: [type: :pos_integer, default: 3600, doc: "Seconds."],
      id_token_expires_in: [type: :pos_integer, default: 3600, doc: "Seconds."],
      refresh_token_expires_in: [type: :pos_integer, default: 30 * @day, doc: "Seconds."],
      refresh_token_reuse_interval: [
        type: :non_neg_integer,
        default: 10,
        doc:
          "Seconds a rotated refresh token still works, for clients retrying a request whose answer they lost. Later reuse revokes the whole chain."
      ],
      require_pushed_authorization_requests: [
        type: :boolean,
        default: false,
        doc: "Only take authorization requests pushed to `/oauth2/par` first (RFC 9126)."
      ],
      client_id_metadata_documents: [
        type: :boolean,
        default: false,
        doc:
          "Accept clients whose `client_id` is an HTTPS URL to their metadata (Client ID Metadata Documents, as MCP clients use). Fetched on first use and when stale, never from private networks, at most 5 KB. Such clients have no secrets."
      ],
      resolve_host: [
        type: {:fun, 1},
        doc:
          "`fn host -> {:ok, [ip_address]} | :error end`: how metadata document hosts are resolved before fetching (DNS by default). Addresses on private networks are refused either way."
      ],
      allow_dynamic_client_registration: [
        type: :boolean,
        default: false,
        doc: "Serve `POST /oauth2/register` (RFC 7591) to signed-in users."
      ],
      allow_unauthenticated_client_registration: [
        type: :boolean,
        default: false,
        doc:
          "Let anyone register public clients (no secret), as MCP clients expect. Needs `allow_dynamic_client_registration`."
      ],
      trusted_clients: [
        type: {:list, :string},
        default: [],
        doc:
          "`client_id`s of your own apps: they skip consent, and their records are cached for 60 seconds on each node (so disabling one takes up to a minute there)."
      ],
      client_reference: [
        type: {:fun, 1},
        doc:
          "`fn ctx -> reference_id | nil end`: who owns clients created now, like the session's active organization. Clients with the same reference are managed by everyone it returns it for."
      ],
      reference_access: [
        type: {:fun, 3},
        doc:
          "`fn user, reference_id, ctx -> boolean end`: whether a user may sign in to a client owned by that reference, like an organization's members only."
      ],
      client_privileges: [
        type: {:fun, 2},
        doc:
          "`fn action, ctx -> boolean end`, for `:create`, `:read`, `:update`, `:delete` and `:rotate` on the client endpoints. Default: signed-in users manage their own clients."
      ],
      validate_redirect_uri: [
        type: {:fun, 3},
        doc:
          "`fn redirect_uri, registered_uris, default_result -> boolean end`, to replace exact matching."
      ],
      metadata: [
        type: {:fun, 1},
        doc: "`fn document -> document end`, to change what the discovery documents advertise."
      ],
      jwt_bearer_subject: [
        type: {:fun, 3},
        doc:
          "Enables the JWT bearer grant (RFC 7523): `fn sub, client, ctx -> user | nil end` finds the user an assertion speaks for. The client signs the assertion with its own keys, so give this grant only to clients you trust to act for those users."
      ],
      claims: [
        type: {:fun, 1},
        doc:
          "`fn %{user: user, client: client, scopes: scopes} -> map end`: extra claims for ID tokens and user info. Protocol claims (`sub`, `iss`, `aud`...) can't be replaced."
      ]
    )
  end
end
