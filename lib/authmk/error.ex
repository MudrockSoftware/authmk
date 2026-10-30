defmodule Authmk.Error do
  @errors %{
    bad_request: {400, "The request is invalid"},
    validation_failed: {422, "Some fields are invalid"},
    invalid_credentials: {401, "Invalid email or password"},
    invalid_password: {401, "Invalid password"},
    unauthorized: {401, "You need to sign in"},
    session_not_fresh: {403, "Sign in again to continue"},
    forbidden: {403, "You are not allowed to do this"},
    invalid_origin: {403, "The request origin is not trusted"},
    invalid_host: {400, "The request host is not allowed"},
    invalid_callback_url: {403, "The callback URL is not trusted"},
    email_not_verified: {403, "Verify your email before signing in"},
    sign_up_disabled: {403, "Sign-up is disabled"},
    user_already_exists: {422, "A user with this email already exists"},
    invalid_email: {422, "The email address is invalid"},
    password_too_short: {422, "The password is too short"},
    password_too_long: {422, "The password is too long"},
    invalid_token: {400, "The link or code is invalid or has expired"},
    email_cannot_be_updated: {422, "The email address can't be changed"},
    credential_account_not_found: {400, "This account has no password"},
    password_already_set: {400, "This account already has a password"},
    not_found: {404, "Not found"},
    feature_disabled: {404, "This feature is not enabled"},
    rate_limited: {429, "Too many requests. Try again later"},
    oauth_provider_not_found: {404, "That sign-in provider isn't set up"},
    state_not_found: {400, "The sign-in request is missing its state"},
    state_mismatch: {400, "The sign-in request expired or came from another browser"},
    no_code: {400, "The provider sent no authorization code"},
    invalid_code: {400, "The provider rejected the authorization code"},
    provider_error: {400, "The provider reported an error"},
    email_not_found: {400, "The provider shared no email address"},
    email_doesnt_match: {400, "The account's email doesn't match yours"},
    additional_verification_required:
      {403, "Finish signing in with another step, like a second factor"},
    invalid_otp: {400, "The code is invalid or has expired"},
    too_many_attempts: {403, "Too many wrong codes. Ask for a new one"},
    discovery_failed: {502, "Couldn't read the provider's OpenID configuration"},
    unable_to_get_user_info: {502, "Couldn't get your profile from the provider"},
    unable_to_link_account: {400, "The account couldn't be linked"},
    account_not_linked:
      {403, "An account with this email exists. Sign in to it, then link this provider"},
    account_already_linked_to_different_user: {409, "This account is linked to another user"},
    account_not_found: {404, "No such account"},
    cannot_unlink_last_account: {400, "You can't unlink your only sign-in method"},
    id_token_not_supported: {400, "This provider doesn't support ID token sign-in"},
    invalid_id_token: {401, "The ID token is invalid"},
    no_refresh_token: {400, "This account has no refresh token"},
    failed_to_refresh_token: {502, "The provider refused to refresh the token"},
    internal_error: {500, "Something went wrong"}
  }

  @moduledoc """
  The error every authmk function and endpoint returns.

  `code` is stable and safe to match on. `message` is English text for
  humans. `details` holds extra data, such as field errors.

  JSON responses look like:

      {"error": {"code": "invalid_credentials", "message": "Invalid email or password", "details": {}}}

  ## Error codes

  | Code | Status | Message |
  |---|---|---|
  #{@errors |> Enum.sort() |> Enum.map_join("\n", fn {code, {status, message}} -> "| `#{code}` | #{status} | #{message} |" end)}

  Plugins add their own codes; see each plugin's docs.
  """

  defexception [:code, :message, status: 400, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), status: pos_integer(), details: map()}

  @doc "Builds an error from a known code. Extra `details` are optional."
  @spec new(atom(), map()) :: t()
  def new(code, details \\ %{}) do
    {status, message} = Map.fetch!(@errors, code)
    %__MODULE__{code: code, message: message, status: status, details: details}
  end

  @doc """
  The message for a built-in error code given as a string (like one from
  `?error=` in a URL), or `nil` for codes authmk doesn't know. Never makes
  atoms from its input.
  """
  @spec message_for(String.t()) :: String.t() | nil
  def message_for(code) when is_binary(code) do
    Enum.find_value(@errors, fn {known, {_status, message}} ->
      Atom.to_string(known) == code and message
    end)
  end

  def message_for(_code), do: nil

  @doc """
  An error with a code of your own, for plugins:

      Authmk.Error.custom(:organization_full, 422, "This organization has no free seats")
  """
  @spec custom(atom(), pos_integer(), String.t(), map()) :: t()
  def custom(code, status, message, details \\ %{}) when is_atom(code) do
    %__MODULE__{code: code, status: status, message: message, details: details}
  end

  @doc "Every known error code with its HTTP status and message."
  @spec codes() :: %{atom() => {pos_integer(), String.t()}}
  def codes, do: @errors

  @doc "Turns an invalid changeset into a `:validation_failed` error with field errors."
  @spec from_changeset(Ecto.Changeset.t()) :: t()
  def from_changeset(%Ecto.Changeset{} = changeset) do
    fields = Ecto.Changeset.traverse_errors(changeset, &interpolate/1)
    new(:validation_failed, %{fields: fields})
  end

  # "should be at least %{count} character(s)" with count: 8 becomes "... 8 ...".
  defp interpolate({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc "JSON-ready map for responses."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{error: %{code: error.code, message: error.message, details: error.details}}
  end
end
