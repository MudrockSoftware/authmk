defmodule Authmk.Endpoints.User do
  @moduledoc false
  # User and account endpoints. See `Authmk.Endpoints`.

  alias Authmk.{
    Background,
    Cookies,
    Credentials,
    Email,
    EmailVerification,
    Error,
    Origin,
    Serializer,
    Sessions,
    Store,
    URL,
    Users,
    Verification
  }

  @delete_purpose "delete-account"

  def update_user(ctx) do
    with {:ok, user} <- Store.update(ctx, :user, ctx.user, Users.input_attrs(ctx), :internal) do
      {:ok, %{user: Serializer.user(ctx, user)}, %{ctx | user: user}}
    end
  end

  def change_email(%{config: config, user: user} = ctx) do
    new_email = Email.normalize(ctx.params.new_email)
    callback_url = ctx.params.callback_url

    with :ok <- enabled(config.user[:change_email][:enabled]),
         :ok <- Origin.check_redirect(config, callback_url),
         :ok <- valid_email(new_email),
         :ok <- email_available(ctx, new_email) do
      if user.email_verified,
        do: change_verified_email(ctx, new_email, callback_url),
        else: change_unverified_email(ctx, new_email, callback_url)
    end
  end

  def delete_user(%{config: config} = ctx) do
    with :ok <- enabled(config.user[:delete_user][:enabled]),
         :ok <- Origin.check_redirect(config, ctx.params.callback_url),
         :ok <- confirm_identity(ctx) do
      if config.user[:delete_user][:verify_with_email] do
        send_delete_link(ctx)
      else
        delete_now(ctx)
      end
    end
  end

  def delete_user_callback(%{config: config, params: params} = ctx) do
    with :ok <- enabled(config.user[:delete_user][:enabled]),
         :ok <- Origin.check_redirect(config, params.callback_url),
         {:ok, %{"user_id" => user_id}} <-
           Verification.consume(ctx, @delete_purpose, params.token),
         :ok <- same_user(ctx, user_id),
         {:ok, _body, ctx} <- delete_now(ctx) do
      if params.callback_url,
        do: {:redirect, params.callback_url, ctx},
        else: {:ok, %{success: true}, ctx}
    end
  end

  def list_accounts(ctx) do
    accounts = Store.all(ctx, :account, user_id: ctx.user.id)
    {:ok, Enum.map(accounts, &Serializer.record(ctx, :account, &1)), ctx}
  end

  # A verified address only changes once the new one confirms.
  defp change_verified_email(ctx, new_email, callback_url) do
    with :ok <- EmailVerification.send_change_email(ctx, ctx.user, new_email, callback_url) do
      {:ok, %{status: true}, ctx}
    end
  end

  defp change_unverified_email(ctx, new_email, callback_url) do
    send? = ctx.config.email_verification[:send_on_sign_up]

    with {:ok, user} <- Store.update(ctx, :user, ctx.user, %{email: new_email}),
         :ok <- EmailVerification.maybe_send_verification(ctx, send?, user, callback_url) do
      {:ok, %{status: true}, %{ctx | user: user}}
    end
  end

  # Deleting needs the password, or a session created moments ago.
  defp confirm_identity(%{params: %{password: password}} = ctx) when is_binary(password),
    do: Credentials.check_password(ctx, ctx.user, password)

  defp confirm_identity(ctx) do
    if Sessions.fresh?(ctx), do: :ok, else: {:error, Error.new(:session_not_fresh)}
  end

  defp send_delete_link(%{config: config, user: user} = ctx) do
    data = %{"user_id" => to_string(user.id)}
    expires_in = config.user[:delete_user][:expires_in]

    with {:ok, token} <- Verification.create(ctx, @delete_purpose, data, expires_in) do
      url =
        URL.endpoint(config, "/delete-user/callback",
          token: token,
          callback_url: ctx.params.callback_url
        )

      Background.run(ctx, fn ->
        config.auth.send_delete_account_verification(%{user: user, url: url, token: token}, ctx)
      end)

      {:ok, %{success: true, message: "Verification email sent"}, ctx}
    end
  end

  defp delete_now(ctx) do
    with {:ok, _user} <- Store.delete(ctx, :user, ctx.user) do
      {:ok, %{success: true}, Cookies.clear_session(%{ctx | session: nil, user: nil})}
    end
  end

  defp email_available(ctx, email) do
    if Store.get_by(ctx, :user, email: email),
      do: {:error, Error.new(:email_cannot_be_updated)},
      else: :ok
  end

  defp valid_email(email) do
    if Email.valid?(email), do: :ok, else: {:error, Error.new(:invalid_email)}
  end

  # The deletion link only works for the signed-in user it was sent to.
  defp same_user(ctx, user_id) do
    if user_id == to_string(ctx.user.id), do: :ok, else: {:error, Error.new(:invalid_token)}
  end

  defp enabled(true), do: :ok
  defp enabled(_disabled), do: {:error, Error.new(:feature_disabled)}
end
