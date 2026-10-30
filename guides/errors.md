# Error reference

Every authmk function and endpoint fails with an `%Authmk.Error{}`:

```elixir
%Authmk.Error{code: :invalid_credentials, status: 401, message: "Invalid email or password", details: %{}}
```

Endpoints send it as JSON with the same status:

```json
{"error": {"code": "invalid_credentials", "message": "Invalid email or password", "details": {}}}
```

## Using codes

- **Match on `code`.** Codes are stable: a code isn't renamed or removed
  before the next major version (see [Stability](stability.md)). Messages
  are English text for people and may be reworded in any release.
- **Show your own text if you like.** authmk is English only. Map codes to
  your own messages, in any language.
- **`details`** holds extra data. `validation_failed` puts field errors in
  `details.fields`, for example `%{fields: %{email: ["can't be blank"]}}`.
- **Some codes are shared on purpose.** To avoid revealing whether an
  account exists, a wrong email and a wrong password both give
  `invalid_credentials`, and requests for links and codes succeed whether or
  not the address is known.
- **Statuses** follow HTTP: 4xx means the request can't succeed as sent; 5xx
  means authmk or a provider failed, and a retry may work.

Your own plugins can add codes with `Authmk.Error.custom/4`.

## Protocol errors

Two plugins answer in the format their standard requires instead:

- **`Authmk.Plugins.OAuthProvider`** and **`Authmk.Plugins.DeviceAuthorization`**
  answer their token, authorization, registration and introspection
  endpoints with OAuth errors, `{"error": "invalid_grant", "error_description": "..."}`
  (RFC 6749, RFC 7591, RFC 8628 and RFC 9449). The redirect-based ones go
  back to the client as `?error=access_denied`. The codes are the RFCs'
  own: `invalid_request`, `invalid_client`, `invalid_grant`,
  `unauthorized_client`, `unsupported_grant_type`,
  `unsupported_response_type`, `invalid_scope`, `invalid_target`,
  `invalid_redirect_uri`, `invalid_client_metadata`, `invalid_dpop_proof`,
  `access_denied`, `login_required`, `consent_required`,
  `authorization_pending`, `slow_down`, `expired_token` and `server_error`.
- **`Authmk.Plugins.SCIM`** answers its `/scim/v2` endpoints with SCIM
  errors (RFC 7644): `{"schemas": ["urn:ietf:params:scim:api:messages:2.0:Error"], "status": "409", "scimType": "uniqueness", "detail": "..."}`.

Everything else uses the codes below. A test checks that this page lists
every code in authmk's source.

## Core

These come from `Authmk.Error.new/2`; `Authmk.Error.codes/0` lists them at runtime.

| Code | Status | Message |
|---|---|---|
| `account_already_linked_to_different_user` | 409 | This account is linked to another user |
| `account_not_found` | 404 | No such account |
| `account_not_linked` | 403 | An account with this email exists. Sign in to it, then link this provider |
| `additional_verification_required` | 403 | Finish signing in with another step, like a second factor |
| `bad_request` | 400 | The request is invalid |
| `cannot_unlink_last_account` | 400 | You can't unlink your only sign-in method |
| `credential_account_not_found` | 400 | This account has no password |
| `discovery_failed` | 502 | Couldn't read the provider's OpenID configuration |
| `email_cannot_be_updated` | 422 | The email address can't be changed |
| `email_doesnt_match` | 400 | The account's email doesn't match yours |
| `email_not_found` | 400 | The provider shared no email address |
| `email_not_verified` | 403 | Verify your email before signing in |
| `failed_to_refresh_token` | 502 | The provider refused to refresh the token |
| `feature_disabled` | 404 | This feature is not enabled |
| `forbidden` | 403 | You are not allowed to do this |
| `id_token_not_supported` | 400 | This provider doesn't support ID token sign-in |
| `internal_error` | 500 | Something went wrong |
| `invalid_callback_url` | 403 | The callback URL is not trusted |
| `invalid_code` | 400 | The provider rejected the authorization code |
| `invalid_credentials` | 401 | Invalid email or password |
| `invalid_email` | 422 | The email address is invalid |
| `invalid_host` | 400 | The request host is not allowed |
| `invalid_id_token` | 401 | The ID token is invalid |
| `invalid_origin` | 403 | The request origin is not trusted |
| `invalid_otp` | 400 | The code is invalid or has expired |
| `invalid_password` | 401 | Invalid password |
| `invalid_request` | 400 | Give the session's id |
| `invalid_request` | 4xx | The request couldn't be read |
| `invalid_token` | 400 | The link or code is invalid or has expired |
| `no_code` | 400 | The provider sent no authorization code |
| `no_refresh_token` | 400 | This account has no refresh token |
| `not_found` | 404 | Not found |
| `oauth_provider_not_found` | 404 | That sign-in provider isn't set up |
| `password_already_set` | 400 | This account already has a password |
| `password_too_long` | 422 | The password is too long |
| `password_too_short` | 422 | The password is too short |
| `provider_error` | 400 | The provider reported an error |
| `rate_limited` | 429 | Too many requests. Try again later |
| `session_not_fresh` | 403 | Sign in again to continue |
| `sign_up_disabled` | 403 | Sign-up is disabled |
| `state_mismatch` | 400 | The sign-in request expired or came from another browser |
| `state_not_found` | 400 | The sign-in request is missing its state |
| `too_many_attempts` | 403 | Too many wrong codes. Ask for a new one |
| `unable_to_get_user_info` | 502 | Couldn't get your profile from the provider |
| `unable_to_link_account` | 400 | The account couldn't be linked |
| `unauthorized` | 401 | You need to sign in |
| `user_already_exists` | 422 | A user with this email already exists |
| `validation_failed` | 422 | Some fields are invalid |

## Payments

`Authmk.Payments` and the provider plugins built on it.

| Code | Status | Message |
|---|---|---|
| `already_subscribed` | 409 | Already subscribed: change plans in the billing portal |
| `invalid_seats` | 422 | Seats must be 1 to 10000; with Commet, also: This plan isn't sold by the seat |
| `no_billing_customer` | 404 | There's no billing account yet |
| `not_scheduled_to_cancel` | 409 | The subscription isn't set to cancel |
| `not_supported` | 400 | The payment provider doesn't support this; or: This subscription is billed by another provider |
| `payment_provider_error` | 502 | "Stripe refused the request", "Chargebee refused the request" and so on, naming the provider |
| `payment_provider_unavailable` | 502 | "Stripe can't be reached", "Chargebee can't be reached" and so on, naming the provider |
| `plan_change_needs_payment` | 402 | The customer must pay for this change: they can change plans in the billing portal (Commet) |
| `plan_not_found` | 404 | No such plan; or: This plan has no annual price |
| `subscription_canceled` | 409 | The subscription is canceled |
| `subscription_not_found` | 404 | No such subscription |

## `Authmk.Plugins.Admin`

| Code | Status | Message |
|---|---|---|
| `admin_session_not_found` | 400 | Sign in again as yourself |
| `banned` | 403 | Your ban reason, or a default message |
| `cannot_ban_yourself` | 400 | You can't ban yourself |
| `cannot_remove_yourself` | 400 | You can't remove yourself |
| `field_not_updatable` | 400 | Names the field |
| `invalid_role` | 422 | Unknown role |
| `not_impersonating` | 400 | You aren't impersonating anyone |
| `user_id_cannot_be_updated` | 400 | A user's id can't be changed |
| `user_not_found` | 404 | User not found |

## `Authmk.Plugins.Anonymous`

| Code | Status | Message |
|---|---|---|
| `already_anonymous` | 400 | You are already signed in anonymously |

## `Authmk.Plugins.APIKey`

| Code | Status | Message |
|---|---|---|
| `api_key_disabled` | 401 | This API key is disabled |
| `api_key_expired` | 401 | This API key has expired |
| `api_key_not_found` | 404 | API key not found |
| `api_key_rate_limited` | 429 | Too many requests with this API key |
| `api_key_usage_exceeded` | 429 | This API key has no uses left |
| `custom_expiry_disabled` | 422 | API keys can't choose their expiry |
| `insufficient_api_key_permissions` | 403 | This API key may not do this |
| `invalid_api_key` | 401 | This API key isn't valid |
| `invalid_expires_in` | 422 | This expiry is out of range |
| `metadata_disabled` | 422 | API keys can't carry metadata |
| `name_required` | 422 | API keys need a name |
| `unknown_configuration` | 422 | Unknown API key configuration |

## `Authmk.Plugins.Captcha`

| Code | Status | Message |
|---|---|---|
| `captcha_failed` | 403 | The captcha wasn't solved |
| `captcha_required` | 400 | Complete the captcha |
| `captcha_unavailable` | 503 | The captcha couldn't be checked; try again |

## `Authmk.Plugins.DeviceAuthorization`

| Code | Status | Message |
|---|---|---|
| `expired_user_code` | 400 | This code has expired |
| `invalid_user_code` | 404 | This code isn't valid |

## `Authmk.Plugins.EmailOTP`

| Code | Status | Message |
|---|---|---|
| `invalid_otp_type` | 400 | Unknown code type |

## `Authmk.Plugins.HaveIBeenPwned`

| Code | Status | Message |
|---|---|---|
| `password_check_unavailable` | 503 | The password couldn't be checked; try again |
| `password_compromised` | 422 | The plugin's `message` option |

## `Authmk.Plugins.JWT`

| Code | Status | Message |
|---|---|---|
| `invalid_jwt` | 401 | The token isn't valid |

## `Authmk.Plugins.MultiSession`

| Code | Status | Message |
|---|---|---|
| `session_not_found` | 404 | No such session on this device |

## `Authmk.Plugins.OAuthProvider`

| Code | Status | Message |
|---|---|---|
| `client_not_found` | 404 | No such client |
| `insufficient_scope` | 403 | The token lacks a scope |
| `invalid_client_metadata` | 400 | Describes the problem |
| `invalid_logout_query` | 400 | The request expired or was changed |
| `invalid_oauth_query` | 400 | The request expired or was changed |
| `invalid_redirect_uri` | 400 | Describes the problem |
| `invalid_scope` | 400 | Only scopes asked for can be granted |
| `invalid_token` | 401 | The token is invalid or expired |

## `Authmk.Plugins.Organization`

| Code | Status | Message |
|---|---|---|
| `already_invited` | 409 | This user is already invited |
| `already_member` | 409 | This user is already a member |
| `cannot_remove_last_owner` | 400 | An organization needs an owner |
| `cannot_remove_last_team` | 400 | An organization needs a team |
| `email_not_verified` | 403 | Verify your email first |
| `invalid_role` | 422 | Unknown role |
| `invitation_expired` | 400 | This invitation has expired |
| `invitation_limit_reached` | 403 | This organization has as many pending invitations as allowed |
| `invitation_not_found` | 404 | Invitation not found |
| `member_not_found` | 404 | Member not found |
| `membership_limit_reached` | 403 | This organization has as many members as allowed |
| `no_active_organization` | 400 | No organization is active; pass organization_id |
| `not_a_member` | 403 | You aren't a member of this organization |
| `organization_creation_disabled` | 403 | You can't create organizations |
| `organization_limit_reached` | 403 | You belong to as many organizations as allowed |
| `organization_not_found` | 404 | Organization not found |
| `owner_required` | 403 | Only owners can do this |
| `role_exists` | 409 | This role exists already |
| `role_in_use` | 409 | Members still have this role |
| `role_limit_reached` | 403 | This organization has as many roles as allowed |
| `role_not_found` | 404 | Role not found |
| `slug_taken` | 422 | This slug is taken |
| `team_limit_reached` | 403 | This organization has as many teams as allowed |
| `team_member_limit_reached` | 403 | This team has as many members as allowed |
| `team_not_found` | 404 | Team not found |
| `user_not_found` | 404 | User not found |

## `Authmk.Plugins.Passkey`

| Code | Status | Message |
|---|---|---|
| `invalid_passkey` | 401 | This passkey isn't valid here |
| `passkey_already_registered` | 409 | This passkey is already registered |
| `passkey_challenge_expired` | 400 | Start again: the passkey request expired |
| `passkey_cloned` | 401 | This passkey may have been copied |
| `passkey_not_found` | 404 | Passkey not found |

## `Authmk.Plugins.PhoneNumber`

| Code | Status | Message |
|---|---|---|
| `invalid_phone_number` | 422 | This phone number isn't valid |
| `phone_number_not_found` | 404 | No account has this phone number |
| `phone_number_not_verified` | 403 | Verify your phone number first |
| `phone_number_taken` | 422 | This phone number belongs to another account |

## `Authmk.Plugins.SCIM`

| Code | Status | Message |
|---|---|---|
| `account_deactivated` | 403 | This account was deactivated by your organization |
| `scim_connection_not_found` | 404 | No such connection |

## `Authmk.Plugins.Security`

| Code | Status | Message |
|---|---|---|
| `bot_blocked` | 403 | Automated requests aren't accepted |
| `disposable_email` | 400 | Use a permanent email address |
| `email_already_used` | 422 | This mailbox already has an account |
| `email_cannot_receive_mail` | 400 | This email domain can't receive mail |
| `ip_blocked` | 403 | Requests from this address aren't accepted |
| `proof_of_work_required` | 400 | Solve a challenge from /security/challenge first |
| `region_blocked` | 403 | This service isn't available in your region |
| `sign_in_blocked` | 403 | This sign-in looks unusual and was blocked |
| `too_many_attempts` | 429 | Too many failed sign-ins from here. Try later |
| `too_many_sign_ups` | 429 | Too many sign-ups from here. Try later |
| `velocity_limited` | 429 | You've done this too often. Try later |

## `Authmk.Plugins.ServiceAccount`

| Code | Status | Message |
|---|---|---|
| `invalid_allowed_ips` | 422 | Allowed IPs must be addresses or CIDR ranges |
| `invalid_role` | 422 | Unknown role |
| `ip_not_allowed` | 403 | This service account may not be used from here |
| `key_not_found` | 404 | API key not found |
| `oauth_client_exists` | 409 | This service account already has OAuth client credentials |
| `service_account_disabled` | 401 | This service account is disabled |
| `service_account_expired` | 401 | This service account has expired |
| `service_account_not_found` | 404 | Service account not found |

## `Authmk.Plugins.SIWE`

| Code | Status | Message |
|---|---|---|
| `email_required` | 400 | An email is needed to sign up |
| `invalid_siwe_message` | 400 | The sign-in message isn't valid |
| `invalid_siwe_nonce` | 401 | Ask for a new nonce and sign again |
| `invalid_siwe_signature` | 401 | The signature doesn't match |
| `invalid_wallet_address` | 400 | This isn't an Ethereum address |

## `Authmk.Plugins.SSO`

| Code | Status | Message |
|---|---|---|
| `account_not_linked` | 403 | Sign in the usual way, then connect SSO |
| `domain_not_verified` | 400 | The TXT record wasn't found; DNS may take a while |
| `email_required` | 400 | The identity provider sent no email |
| `invalid_sso_provider` | 400 | The provider has no domain |
| `provider_error` | 400 | The identity provider refused |
| `sign_up_disabled` | 403 | Ask an admin for an account |
| `sso_provider_not_found` | 404 | No such provider; at sign-in: No single sign-on for this, or No such SAML provider |
| `sso_provider_unavailable` | 502 | The identity provider can't be reached |

## `Authmk.Plugins.TwoFactor`

| Code | Status | Message |
|---|---|---|
| `invalid_two_factor_code` | 401 | The code is invalid or has expired |
| `too_many_two_factor_attempts` | 429 | Too many wrong codes. Sign in again |
| `two_factor_already_enabled` | 400 | Two-factor authentication is already on |
| `two_factor_expired` | 401 | Sign in again: the two-factor step expired |
| `two_factor_not_enabled` | 400 | Two-factor authentication isn't set up |

## `Authmk.Plugins.Username`

| Code | Status | Message |
|---|---|---|
| `invalid_display_username` | 422 | This display username isn't allowed |
| `invalid_username` | 422 | Usernames may only contain letters, numbers, dots and underscores |
| `username_immutable` | 403 | Usernames can't be changed |
| `username_taken` | 422 | This username is taken |
| `username_too_long` | 422 | This username is too long |
| `username_too_short` | 422 | This username is too short |
