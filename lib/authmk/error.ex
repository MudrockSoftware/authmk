defmodule Authmk.Error do
  @moduledoc """
  The error every authmk function and endpoint returns.

  `code` is stable and safe to match on. `message` is English text for
  humans. `details` holds extra data, such as field errors.

  JSON responses look like:

      {"error": {"code": "invalid_credentials", "message": "Invalid email or password", "details": {}}}
  """

  defexception [:code, :message, status: 400, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), status: pos_integer(), details: map()}

  @errors %{
    bad_request: {400, "The request is invalid"},
    validation_failed: {422, "Some fields are invalid"},
    invalid_credentials: {401, "Invalid email or password"},
    invalid_password: {401, "Invalid password"},
    unauthorized: {401, "You need to sign in"},
    session_not_fresh: {403, "Sign in again to continue"},
    forbidden: {403, "You are not allowed to do this"},
    invalid_origin: {403, "The request origin is not trusted"},
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
    not_found: {404, "Not found"},
    feature_disabled: {404, "This feature is not enabled"},
    rate_limited: {429, "Too many requests. Try again later"},
    internal_error: {500, "Something went wrong"}
  }

  @doc "Builds an error from a known code. Extra `details` are optional."
  @spec new(atom(), map()) :: t()
  def new(code, details \\ %{}) do
    {status, message} = Map.fetch!(@errors, code)
    %__MODULE__{code: code, message: message, status: status, details: details}
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
