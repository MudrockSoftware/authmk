defmodule Authmk.OAuth.Providers.Microsoft do
  @moduledoc """
  Sign in with Microsoft Entra ID (OpenID Connect), for work, school and
  personal Microsoft accounts.

      social_providers: [microsoft: [client_id: "...", client_secret: "..."]]

  Register an app at
  <https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade>
  with the web redirect URI `<base_url>/auth/callback/microsoft`.

  `tenant_id:` picks who may sign in:

    * `"common"` (the default) - any work, school or personal account
    * `"organizations"` - work and school accounts only
    * `"consumers"` - personal accounts only
    * a tenant id (a GUID) - that tenant's accounts only

  For a tenant named by its domain, also set `issuer:
  "https://login.microsoftonline.com/<tenant-id>/v2.0"`. `authority:` changes
  the login host (default `https://login.microsoftonline.com`), for national
  clouds.

  Accounts are keyed by the `oid` claim, which stays the same across apps;
  ID tokens without one are refused, as are tokens whose issuer isn't
  `<authority>/<tid>/v2.0` for their own tenant (`tid`). Microsoft sends no `email_verified` claim unless
  you configure it as an optional claim; without it, the email counts as
  verified only when it is in `verified_primary_email` or
  `verified_secondary_email`.

  The profile photo comes from Microsoft Graph as a `data:` URL, at
  `profile_photo_size` pixels (default 48). Set `disable_profile_photo: true`
  to skip it. Clients may also sign in with a Microsoft ID token.
  """

  use Authmk.OAuth.Provider

  alias Authmk.OAuth.{HTTP, Provider}

  @authority "https://login.microsoftonline.com"
  # The tenant every personal Microsoft account belongs to.
  @consumers_tenant "9188040d-6c67-4c5b-b112-36a304b66dad"
  @photo_sizes [48, 64, 96, 120, 240, 360, 432, 504, 648]

  @impl true
  def config do
    [
      name: "Microsoft",
      scopes: ["openid", "profile", "email", "User.Read", "offline_access"],
      id_token_sign_in: true,
      id_token_algorithms: ["RS256"],
      id_token_max_age: 3600
    ]
  end

  @impl true
  def options_schema do
    [
      tenant_id: [
        type: :string,
        default: "common",
        doc: "Microsoft: `common`, `organizations`, `consumers`, or a tenant."
      ],
      authority: [type: :string, default: @authority, doc: "Microsoft: the login host."],
      profile_photo_size: [type: {:in, @photo_sizes}, default: 48],
      disable_profile_photo: [type: :boolean, default: false]
    ]
  end

  @impl true
  def endpoints(options) do
    base = "#{authority(options)}/#{tenant(options)}"

    [
      authorize_url: base <> "/oauth2/v2.0/authorize",
      token_url: base <> "/oauth2/v2.0/token",
      jwks_url: base <> "/discovery/v2.0/keys"
    ]
  end

  # Every tenant signs with the same keys, so the claims must show the
  # token came from a tenant the app allows, and the issuer must be that
  # tenant's own.
  @impl true
  def validate_claims(%{"tid" => tid, "iss" => issuer}, provider)
      when is_binary(tid) and is_binary(issuer) do
    own_issuer = "#{authority(provider.options)}/#{tid}/v2.0"

    if issuer == own_issuer and tenant_allowed?(tenant(provider.options), tid),
      do: :ok,
      else: {:error, :issuer_mismatch}
  end

  def validate_claims(_claims, _provider), do: {:error, :issuer_mismatch}

  @impl true
  def user_info(tokens, provider, ctx) do
    with {:ok, claims} <- Provider.default_user_info(tokens, provider, ctx) do
      case photo(ctx, provider, tokens.access_token) do
        nil -> {:ok, claims}
        picture -> {:ok, Map.put(claims, "picture", picture)}
      end
    end
  end

  @impl true
  def map_profile(%{"oid" => oid} = profile, _tokens) when is_binary(oid) and oid != "" do
    {:ok,
     %{
       id: oid,
       email: profile["email"],
       email_verified: email_verified?(profile),
       name: profile["name"],
       image: profile["picture"]
     }}
  end

  def map_profile(_profile, _tokens), do: {:error, :no_object_id}

  defp authority(options), do: String.trim_trailing(options[:authority] || @authority, "/")
  defp tenant(options), do: options[:tenant_id] || "common"

  defp tenant_allowed?("common", _tid), do: true
  defp tenant_allowed?("organizations", tid), do: tid != @consumers_tenant
  defp tenant_allowed?("consumers", tid), do: tid == @consumers_tenant

  # A tenant GUID must match; a tenant domain is checked by its `issuer:`.
  defp tenant_allowed?(tenant, tid) do
    case Ecto.UUID.cast(tenant) do
      {:ok, _guid} -> String.downcase(tenant) == tid
      :error -> true
    end
  end

  defp email_verified?(%{"email_verified" => verified}), do: verified in [true, "true"]

  defp email_verified?(%{"email" => email} = profile) when is_binary(email) do
    email in List.wrap(profile["verified_primary_email"]) or
      email in List.wrap(profile["verified_secondary_email"])
  end

  defp email_verified?(_profile), do: false

  # A missing photo is common (and not an error): the user just has none.
  defp photo(_ctx, _provider, nil), do: nil

  defp photo(ctx, provider, access_token) do
    size = provider.options[:profile_photo_size]
    url = "https://graph.microsoft.com/v1.0/me/photos/#{size}x#{size}/$value"

    with false <- provider.options[:disable_profile_photo],
         {:ok, 200, image} when is_binary(image) <-
           HTTP.get(ctx, url, [{"authorization", "Bearer " <> access_token}]) do
      "data:image/jpeg;base64," <> Base.encode64(image)
    else
      _no_photo -> nil
    end
  end
end
