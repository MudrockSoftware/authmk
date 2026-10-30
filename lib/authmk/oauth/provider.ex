defmodule Authmk.OAuth.Provider do
  @moduledoc """
  A social sign-in provider: its endpoints, default scopes, and how its
  profile becomes a user.

      defmodule MyApp.Auth.Acme do
        use Authmk.OAuth.Provider

        @impl true
        def config do
          [
            name: "Acme",
            authorize_url: "https://acme.example/oauth/authorize",
            token_url: "https://acme.example/oauth/token",
            userinfo_url: "https://acme.example/api/me",
            scopes: ["profile", "email"]
          ]
        end

        @impl true
        def map_profile(profile, _tokens) do
          {:ok, %{id: profile["uid"], email: profile["mail"], email_verified: true, name: profile["name"], image: nil}}
        end
      end

  Enable it with `social_providers: [acme: [provider: MyApp.Auth.Acme, client_id: ..., client_secret: ...]]`.

  The defaults suit OpenID Connect: `user_info/3` reads the ID token's
  claims or the userinfo endpoint, and `map_profile/2` maps the standard
  claims (`sub`, `email`, `email_verified`, `name`, `picture`).

  ## Static config

    * `:name` - display name
    * `:authorize_url`, `:token_url`, `:userinfo_url`
    * `:issuer`, `:jwks_url` - for verifying ID tokens
    * `:discovery_url` - an OpenID Connect discovery document, which fills
      in the endpoints left out (see `Authmk.OAuth.Discovery`)
    * `:end_session_url` - the provider's logout endpoint
    * `:scopes` - default scopes
    * `:scope_separator` - joins the scopes in the authorization URL (default `" "`)
    * `:pkce` - send a PKCE challenge (default `true`). A provider that lets
      apps turn PKCE off declares a `:pkce` option in `options_schema/0`,
      which then wins.
    * `:token_auth` - `:post` (client secret in the body, default), `:basic`,
      or `:none` (public clients). Apps can override it with the `token_auth` option.
    * `:id_token_sign_in` - whether clients may sign in with an ID token
    * `:id_token_algorithms` - allowed signing algorithms (default: any
      asymmetric one)
    * `:id_token_max_age` - refuse ID tokens issued longer ago, in seconds
    * `:requires_email` - `false` for providers that give no email: their
      accounts can only be linked to a signed-in user (`POST /link-social`),
      then sign that user in; they never create users (default `true`)
  """

  alias Authmk.Context
  alias Authmk.OAuth.{HTTP, Tokens}

  @typedoc "A token request form, with `:grant_type` and the grant's params."
  @type token_form :: keyword()

  @typedoc "A user as the provider describes them."
  @type user_info :: %{
          id: String.t(),
          email: String.t() | nil,
          email_verified: boolean(),
          name: String.t() | nil,
          image: String.t() | nil
        }

  defstruct [
    :id,
    :module,
    :name,
    :client_id,
    :client_secret,
    :authorize_url,
    :token_url,
    :userinfo_url,
    :issuer,
    :jwks_url,
    :discovery_url,
    :end_session_url,
    scopes: [],
    scope_separator: " ",
    pkce: true,
    token_auth: :post,
    id_token_sign_in: false,
    id_token_algorithms: nil,
    id_token_max_age: nil,
    requires_email: true,
    audiences: [],
    options: []
  ]

  @type t :: %__MODULE__{}

  @doc "Static settings. See the module docs."
  @callback config() :: keyword()

  @doc "Fetches the provider's profile for these tokens."
  @callback user_info(Tokens.t(), t(), Context.t()) :: {:ok, map()} | {:error, term()}

  @doc "Turns the profile into a user. Return `{:error, reason}` to refuse sign-in."
  @callback map_profile(profile :: map(), Tokens.t()) :: {:ok, user_info()} | {:error, term()}

  @doc """
  `map_profile/2` for providers whose mapping depends on the app's options.
  The default calls `map_profile/2`.
  """
  @callback map_profile(profile :: map(), Tokens.t(), t()) ::
              {:ok, user_info()} | {:error, term()}

  @doc """
  Extra authorization URL params, like `access_type: \"offline\"`. They
  replace the standard params of the same name, and `nil` leaves a param
  out, for providers that call `client_id` something else.
  """
  @callback authorize_params(t()) :: keyword()

  @doc """
  Sends a token request and returns the token endpoint's response. The
  default, `default_token_request/3`, POSTs the form to `:token_url` with
  the client's credentials. Override it for providers with non-standard
  token requests.
  """
  @callback token_request(Context.t(), t(), token_form()) :: HTTP.response()

  @doc """
  Endpoints that depend on the app's options, like a tenant or region:
  `:authorize_url`, `:token_url`, `:userinfo_url`, `:issuer`, `:jwks_url`.
  They win over `config/0`; URLs the app sets explicitly win over them.
  """
  @callback endpoints(options :: keyword()) :: keyword()

  @doc """
  Verifies an ID token, one a client sends to sign in or one from the code
  exchange. `opts` are `Authmk.OAuth.IDToken.verify/5`'s (`nonce_required:`).
  The default checks it against the provider's JWKS with
  `Authmk.OAuth.IDToken.verify/5`. Override it for providers with their own
  verification, like a verify endpoint.
  """
  @callback verify_id_token(
              Context.t(),
              t(),
              token :: String.t(),
              nonce :: String.t() | nil,
              opts :: keyword()
            ) :: {:ok, map()} | {:error, atom()}

  @doc """
  Extra checks on verified ID token claims, like a tenant rule. Runs for
  every ID token, from clients and from the code exchange. The default
  accepts everything.
  """
  @callback validate_claims(claims :: map(), t()) :: :ok | {:error, atom()}

  @doc """
  NimbleOptions keys for options only this provider takes (like a tenant or
  region). They are validated with the common options and available in
  `provider.options`.
  """
  @callback options_schema() :: keyword()

  defmacro __using__(_opts) do
    quote do
      @behaviour Authmk.OAuth.Provider

      @impl Authmk.OAuth.Provider
      def user_info(tokens, provider, ctx),
        do: unquote(__MODULE__).default_user_info(tokens, provider, ctx)

      @impl Authmk.OAuth.Provider
      def map_profile(profile, _tokens), do: unquote(__MODULE__).standard_claims(profile)

      @impl Authmk.OAuth.Provider
      def map_profile(profile, tokens, _provider), do: map_profile(profile, tokens)

      @impl Authmk.OAuth.Provider
      def authorize_params(_provider), do: []

      @impl Authmk.OAuth.Provider
      def options_schema, do: []

      @impl Authmk.OAuth.Provider
      def token_request(ctx, provider, form),
        do: unquote(__MODULE__).default_token_request(ctx, provider, form)

      @impl Authmk.OAuth.Provider
      def endpoints(_options), do: []

      @impl Authmk.OAuth.Provider
      def verify_id_token(ctx, provider, token, nonce, opts),
        do: unquote(Authmk.OAuth.IDToken).verify(ctx, provider, token, nonce, opts)

      @impl Authmk.OAuth.Provider
      def validate_claims(_claims, _provider), do: :ok

      defoverridable user_info: 3,
                     map_profile: 2,
                     map_profile: 3,
                     authorize_params: 1,
                     options_schema: 0,
                     token_request: 3,
                     endpoints: 1,
                     verify_id_token: 5,
                     validate_claims: 2
    end
  end

  @doc "Builds a provider from its module and the app's options for it."
  @spec new(atom(), module(), keyword()) :: t()
  def new(id, module, options) do
    config = module.config()
    endpoints = module.endpoints(options)
    # The app's explicit setting, then the option-derived one, then the static one.
    pick = fn key -> options[key] || endpoints[key] || config[key] end

    struct!(__MODULE__,
      id: id,
      module: module,
      name: options[:name] || config[:name],
      client_id: options[:client_id],
      client_secret: options[:client_secret],
      authorize_url: pick.(:authorize_url),
      token_url: pick.(:token_url),
      userinfo_url: pick.(:userinfo_url),
      issuer: pick.(:issuer),
      jwks_url: pick.(:jwks_url),
      discovery_url: pick.(:discovery_url),
      end_session_url: pick.(:end_session_url),
      scopes: config[:scopes] || [],
      scope_separator: Keyword.get(config, :scope_separator, " "),
      pkce: Keyword.get(options, :pkce, Keyword.get(config, :pkce, true)),
      token_auth: options[:token_auth] || Keyword.get(config, :token_auth, :post),
      id_token_sign_in:
        Keyword.get(options, :id_token_sign_in, Keyword.get(config, :id_token_sign_in, false)),
      id_token_algorithms: config[:id_token_algorithms],
      id_token_max_age: config[:id_token_max_age],
      requires_email: Keyword.get(config, :requires_email, true),
      audiences: [options[:client_id] | List.wrap(options[:audience])],
      options: options
    )
  end

  @doc """
  The default `user_info/3`: the ID token's claims when there is one (verified
  against the provider's keys when it has a JWKS), merged over the userinfo
  endpoint's answer when the provider has one.
  """
  @spec default_user_info(Tokens.t(), t(), Context.t()) :: {:ok, map()} | {:error, term()}
  def default_user_info(%Tokens{} = tokens, provider, ctx) do
    claims = tokens.claims || unverified_claims(tokens.id_token)

    case provider.userinfo_url do
      nil ->
        if claims == %{}, do: {:error, :no_user_info}, else: {:ok, claims}

      url ->
        with {:ok, info} <- get_json(ctx, url, tokens.access_token),
             do: {:ok, Map.merge(claims, info)}
    end
  end

  @doc """
  The default `token_request/3`: POSTs the form to the token endpoint, with
  the client secret in the form or in HTTP Basic auth (`:token_auth`).
  """
  @spec default_token_request(Context.t(), t(), token_form()) :: HTTP.response()
  def default_token_request(ctx, %__MODULE__{} = provider, form) do
    {form, headers} = client_auth(provider, form)
    HTTP.post_form(ctx, provider.token_url, form, headers)
  end

  defp client_auth(%__MODULE__{token_auth: :basic} = provider, form) do
    credentials = Base.encode64("#{provider.client_id}:#{provider.client_secret}")
    {form, [{"authorization", "Basic " <> credentials}]}
  end

  # Public clients prove nothing but their id; PKCE protects the code.
  defp client_auth(%__MODULE__{token_auth: :none} = provider, form),
    do: {[client_id: provider.client_id] ++ form, []}

  defp client_auth(%__MODULE__{} = provider, form) do
    secret = if provider.client_secret, do: [client_secret: provider.client_secret], else: []
    {[client_id: provider.client_id] ++ secret ++ form, []}
  end

  @doc "Maps the standard OpenID Connect claims."
  @spec standard_claims(map()) :: {:ok, user_info()} | {:error, term()}
  def standard_claims(%{"sub" => sub} = profile) do
    {:ok,
     %{
       id: to_string(sub),
       email: profile["email"],
       email_verified: profile["email_verified"] in [true, "true"],
       name: profile["name"],
       image: profile["picture"]
     }}
  end

  def standard_claims(_profile), do: {:error, :no_subject}

  @doc "GET a JSON resource with a bearer token."
  @spec get_json(Context.t(), String.t(), String.t()) :: {:ok, map() | list()} | {:error, term()}
  def get_json(ctx, url, access_token) do
    ctx |> HTTP.get(url, [bearer(access_token)]) |> json_response()
  end

  @doc "POST to a JSON API with a bearer token. A `nil` body sends no body."
  @spec post_json(Context.t(), String.t(), String.t(), term()) ::
          {:ok, map() | list()} | {:error, term()}
  def post_json(ctx, url, access_token, body) do
    ctx |> HTTP.post_json(url, body, [bearer(access_token)]) |> json_response()
  end

  defp bearer(access_token), do: {"authorization", "Bearer " <> access_token}

  defp json_response({:ok, 200, body}) when is_map(body) or is_list(body), do: {:ok, body}
  defp json_response({:ok, status, _body}), do: {:error, {:http_status, status}}
  defp json_response({:error, reason}), do: {:error, reason}

  # Claims without checking the signature. Only for ID tokens that came
  # straight from the provider's token endpoint over TLS, which OpenID
  # Connect allows. Tokens from clients go through Authmk.OAuth.IDToken.
  defp unverified_claims(nil), do: %{}

  defp unverified_claims(token) do
    %JOSE.JWT{fields: claims} = JOSE.JWT.peek_payload(token)
    claims
  rescue
    _malformed -> %{}
  end
end
