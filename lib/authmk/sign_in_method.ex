defmodule Authmk.SignInMethod do
  @moduledoc false
  # How a request signs someone in, named the way people know it ("email",
  # "github", "passkey"), from the endpoint serving it. For
  # Authmk.Plugins.LastSignInMethod and the audit log.

  alias Authmk.Context

  @methods %{
    sign_in_email: "email",
    sign_up_email: "email",
    sign_in_username: "username",
    sign_in_phone_number: "phone-number",
    sign_in_email_otp: "email-otp",
    magic_link_verify: "magic-link",
    passkey_verify_authentication: "passkey",
    siwe_verify: "siwe",
    one_tap_callback: "google",
    one_tap_redirect: "google"
  }

  @social [:callback, :callback_post, :sign_in_social]
  @sso [:sso_callback, :sso_saml_acs]
  @second_factor [:verify_totp, :verify_two_factor_otp, :verify_backup_code]

  # Endpoints where a wrong answer is a failed sign-in.
  @attempts Map.keys(@methods) -- [:sign_up_email]
  @attempts @attempts ++ (@social -- [:sign_in_social]) ++ @sso ++ @second_factor

  @doc "The method of `endpoint` (an endpoint's name), or `nil` for endpoints that aren't sign-ins."
  @spec of(atom(), Context.t()) :: String.t() | nil
  def of(endpoint, %Context{params: params}) when endpoint in @social, do: provider(params)
  def of(endpoint, _ctx), do: @methods[endpoint]

  @doc "Like `of/2`, and also names SSO and second-factor steps, for counting sign-ins."
  @spec describe(atom(), Context.t()) :: String.t() | nil
  def describe(endpoint, _ctx) when endpoint in @sso, do: "sso"
  def describe(endpoint, _ctx) when endpoint in @second_factor, do: "two-factor"
  def describe(endpoint, ctx), do: of(endpoint, ctx)

  @doc "Whether an error from `endpoint` is a failed sign-in."
  @spec attempt?(atom()) :: boolean()
  def attempt?(endpoint), do: endpoint in @attempts

  defp provider(params) when is_map(params) do
    case params[:provider] do
      provider when is_binary(provider) -> provider
      _none -> nil
    end
  end

  defp provider(_params), do: nil
end
