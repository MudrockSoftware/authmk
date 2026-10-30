defmodule PlugApp.Auth do
  use Authmk,
    otp_app: :plug_app,
    repo: PlugApp.Repo,
    plugins: [
      Authmk.Plugins.EmailPassword,
      Authmk.Plugins.Username,
      Authmk.Plugins.Anonymous,
      {Authmk.Plugins.PhoneNumber,
       send_otp: &__MODULE__.send_phone_code/2, sign_up_on_verification: true},
      {Authmk.Plugins.MagicLink, send_magic_link: &__MODULE__.send_magic_link/2},
      {Authmk.Plugins.EmailOTP, send_otp: &__MODULE__.send_email_code/2},
      Authmk.Plugins.Passkey,
      Authmk.Plugins.OneTap,
      Authmk.Plugins.SIWE,
      Authmk.Plugins.Admin,
      {Authmk.Plugins.Organization, send_invitation_email: &__MODULE__.send_invitation/2},
      {Authmk.Plugins.APIKey, enable_sessions: true},
      Authmk.Plugins.ServiceAccount,
      Authmk.Plugins.Bearer,
      Authmk.Plugins.JWT,
      Authmk.Plugins.MultiSession,
      # Sign-ins that end at the mobile app (plugapp://...) bring it a token.
      {Authmk.Plugins.OneTimeToken, deep_links: ["plugapp://"]},
      Authmk.Plugins.DeviceAuthorization,
      Authmk.Plugins.HaveIBeenPwned,
      {Authmk.Plugins.LastSignInMethod, store_in_database: true},
      # The API description at /auth/open-api/generate-schema, browsable at
      # /auth/reference. Turn the page off in production with reference: false.
      Authmk.Plugins.OpenAPI,
      # Other apps sign in with this one ("Sign in with ...", OpenID Connect).
      # The MCP server at /mcp: MCP clients register themselves, or name
      # themselves by the URL of their metadata document.
      {Authmk.Plugins.OAuthProvider,
       login_page: "/sign-in",
       consent_page: "/consent",
       scopes: ["openid", "profile", "email", "offline_access"],
       resources: &__MODULE__.mcp_resources/0,
       allow_dynamic_client_registration: true,
       allow_unauthenticated_client_registration: true,
       client_id_metadata_documents: true},
      # Customers' directories provision their people (SCIM 2.0 at /auth/scim/v2).
      {Authmk.Plugins.SCIM, can_manage: &__MODULE__.organization_admin?/3},
      # Single sign-on with customers' identity providers; see config.
      {Authmk.Plugins.SSO, default_providers: &__MODULE__.sso_providers/0},
      # Who did what, when: the user's own history at /auth/audit-log/list.
      {Authmk.Plugins.AuditLog, can_view_all: &__MODULE__.admin?/1},
      # Credential-stuffing blocking and disposable-email refusal by default.
      Authmk.Plugins.Security,
      {Authmk.Plugins.OAuthProxy,
       production_url: &__MODULE__.oauth_proxy_url/0, secret: &__MODULE__.oauth_proxy_secret/0},
      # Cloudflare's test secret, which passes every token; use your own.
      {Authmk.Plugins.Captcha,
       provider: :turnstile,
       secret_key: "1x0000000000000000000000000000000AA",
       endpoints: [:request_password_reset]},
      {Authmk.Plugins.TwoFactor, issuer: "PlugApp", send_otp: &__MODULE__.send_two_factor_code/2}
    ]

  import Swoosh.Email

  # Admins (Authmk.Plugins.Admin's role) read everyone's audit log.
  def admin?(%{user: user}), do: user.role == "admin"

  # Owners and admins of an organization manage its SCIM connections.
  def organization_admin?(_action, organization_id, %{user: user} = ctx) do
    case Authmk.Store.get_by(ctx, :member, organization_id: organization_id, user_id: user.id) do
      %{role: role} -> role in ["owner", "admin"]
      nil -> false
    end
  end

  def sso_providers, do: Application.get_env(:plug_app, :sso_providers, [])

  @doc "The MCP server's URL, from the base URL in config."
  def mcp_url, do: Application.fetch_env!(:plug_app, __MODULE__)[:base_url] <> "/mcp"
  def mcp_resources, do: [mcp_url()]

  # Social sign-in through production's callback; see config/runtime.exs.
  def oauth_proxy_url, do: Application.fetch_env!(:plug_app, :oauth_proxy)[:production_url]
  def oauth_proxy_secret, do: Application.fetch_env!(:plug_app, :oauth_proxy)[:secret]

  @impl Authmk
  def send_verification_email(%{user: user, url: url}, _ctx) do
    deliver(user.email, "Verify your email", "Open this link to verify your email:\n\n#{url}")
  end

  @impl Authmk
  def send_reset_password(%{user: user, url: url}, _ctx) do
    deliver(user.email, "Reset your password", "Open this link to reset your password:\n\n#{url}")
  end

  def send_two_factor_code(%{user: user, otp: code}, _ctx) do
    deliver(user.email, "Your sign-in code", "Your sign-in code is #{code}")
  end

  def send_phone_code(message, ctx),
    do: Authmk.SMS.send_otp(PlugApp.SMS, message, ctx, app_name: "PlugApp")

  # authmk's ready-made email, through the app's mailer.
  def send_magic_link(data, ctx) do
    data
    |> Authmk.Emails.magic_link(ctx,
      from: {"PlugApp", "no-reply@example.com"},
      app_name: "PlugApp"
    )
    |> PlugApp.Mailer.deliver()
  end

  def send_email_code(%{email: email, otp: code}, _ctx) do
    deliver(email, "Your code", "Your code is #{code}")
  end

  def send_invitation(%{id: id, email: email, organization: organization}, _ctx) do
    deliver(
      email,
      "Join #{organization.name}",
      "You're invited to #{organization.name}. Your invitation id is #{id}."
    )
  end

  defp deliver(to, subject, body) do
    new()
    |> to(to)
    |> from({"PlugApp", "no-reply@example.com"})
    |> subject(subject)
    |> text_body(body)
    |> PlugApp.Mailer.deliver()
  end
end
