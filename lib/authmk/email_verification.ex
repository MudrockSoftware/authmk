defmodule Authmk.EmailVerification do
  @moduledoc """
  Sends email verification links. The link points to `GET /verify-email`.

  The same flow confirms email changes: the token then also carries the new
  address, which replaces the old one once the link is opened.
  """

  alias Authmk.{Background, Context, Error, URL, Verification}

  @purpose "email-verification"

  @doc "The verification token purpose."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc "Sends a link that verifies the user's current email address."
  @spec send_verification(Context.t(), struct(), String.t() | nil) :: :ok | {:error, Error.t()}
  def send_verification(ctx, user, callback_url) do
    data = %{"user_id" => to_string(user.id), "email" => user.email}

    with {:ok, token, url} <- create_link(ctx, data, callback_url) do
      Background.run(ctx, fn ->
        ctx.config.auth.send_verification_email(%{user: user, url: url, token: token}, ctx)
      end)
    end
  end

  @doc "Sends a verification link when `send?` is true."
  @spec maybe_send_verification(Context.t(), boolean(), struct(), String.t() | nil) ::
          :ok | {:error, Error.t()}
  def maybe_send_verification(ctx, true, user, callback_url),
    do: send_verification(ctx, user, callback_url)

  def maybe_send_verification(_ctx, _send?, _user, _callback_url), do: :ok

  @doc "Sends a link to `new_email` that moves the user to that address."
  @spec send_change_email(Context.t(), struct(), String.t(), String.t() | nil) ::
          :ok | {:error, Error.t()}
  def send_change_email(ctx, user, new_email, callback_url) do
    data = %{"user_id" => to_string(user.id), "email" => user.email, "new_email" => new_email}

    with {:ok, token, url} <- create_link(ctx, data, callback_url) do
      Background.run(ctx, fn ->
        ctx.config.auth.send_change_email_verification(
          %{user: user, new_email: new_email, url: url, token: token},
          ctx
        )
      end)
    end
  end

  defp create_link(%Context{config: config} = ctx, data, callback_url) do
    expires_in = config.email_verification[:expires_in]

    with {:ok, token} <- Verification.create(ctx, @purpose, data, expires_in) do
      {:ok, token, URL.endpoint(ctx, "/verify-email", token: token, callback_url: callback_url)}
    end
  end
end
