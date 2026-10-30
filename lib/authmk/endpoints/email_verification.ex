defmodule Authmk.Endpoints.EmailVerification do
  @moduledoc false
  # Email verification endpoints. See `Authmk.Endpoints`.

  alias Authmk.{
    Background,
    Email,
    EmailVerification,
    Error,
    Origin,
    Serializer,
    Sessions,
    Store,
    URL,
    Verification
  }

  # Always answers the same way, so it can't be used to find registered emails.
  def send(%{params: params} = ctx) do
    with :ok <- Origin.check_redirect(ctx, params.callback_url),
         :ok <- send_if_unverified(ctx, recipient(ctx)) do
      {:ok, %{status: true}, ctx}
    end
  end

  def verify(%{params: params} = ctx) do
    with :ok <- Origin.check_redirect(ctx, params.callback_url) do
      case verify_token(ctx, params.token) do
        {:ok, user, ctx} ->
          success(ctx, user)

        {:error, %Error{} = error} when is_binary(params.callback_url) ->
          {:redirect, URL.append_query(params.callback_url, error: error.code), ctx}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp send_if_unverified(ctx, %{email_verified: false} = user),
    do: EmailVerification.send_verification(ctx, user, ctx.params.callback_url)

  defp send_if_unverified(_ctx, _verified_or_unknown), do: :ok

  defp recipient(%{user: user}) when not is_nil(user), do: user

  defp recipient(%{params: %{email: email}} = ctx) when is_binary(email),
    do: Store.get_by(ctx, :user, email: Email.normalize(email))

  defp recipient(_ctx), do: nil

  defp verify_token(ctx, token) do
    with {:ok, data} <- Verification.consume(ctx, EmailVerification.purpose(), token),
         {:ok, user} <- fetch_user(ctx, data["user_id"]),
         _ = ctx.config.auth.before_email_verification(user, ctx),
         {:ok, user} <- apply_verification(ctx, user, data) do
      Background.callback(ctx, :after_email_verification, user)
      {:ok, user, refresh_signed_in_user(ctx, user)}
    end
  end

  defp fetch_user(ctx, user_id) do
    case Store.get_by(ctx, :user, id: user_id) do
      nil -> invalid_token()
      user -> {:ok, user}
    end
  end

  # Keeps the context's user up to date when the verified user is signed in.
  defp refresh_signed_in_user(%{user: nil} = ctx, _user), do: ctx
  defp refresh_signed_in_user(ctx, user), do: %{ctx | user: user}

  # A change-email token moves the user to the new address.
  defp apply_verification(ctx, user, %{"new_email" => new_email}) do
    if Store.get_by(ctx, :user, email: new_email),
      do: {:error, Error.new(:email_cannot_be_updated)},
      else: Store.update(ctx, :user, user, %{email: new_email, email_verified: true})
  end

  # A plain token only counts while the user still has the address it was sent to.
  defp apply_verification(ctx, user, %{"email" => email}) do
    if user.email == email,
      do: Store.update(ctx, :user, user, %{email_verified: true}),
      else: invalid_token()
  end

  defp success(%{params: params, config: config} = ctx, user) do
    auto_sign_in = config.email_verification[:auto_sign_in_after_verification]

    with {:ok, ctx, challenge} <- maybe_sign_in(ctx, user, auto_sign_in) do
      body = Map.merge(%{status: true, user: Serializer.user(ctx, user)}, challenge)

      case challenge[:redirect_url] || params.callback_url do
        nil -> {:ok, body, ctx}
        url -> {:redirect, url, ctx}
      end
    end
  end

  # A sign-in that needs another step (a second factor) goes on from there.
  defp maybe_sign_in(%{session: nil} = ctx, user, true) do
    case Sessions.sign_in(ctx, user) do
      {:ok, ctx} -> {:ok, ctx, %{}}
      {:challenge, challenge, ctx} -> {:ok, ctx, challenge}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_sign_in(ctx, _user, _auto_sign_in), do: {:ok, ctx, %{}}

  defp invalid_token, do: {:error, Error.new(:invalid_token)}
end
