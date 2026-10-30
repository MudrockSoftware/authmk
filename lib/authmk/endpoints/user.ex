defmodule Authmk.Endpoints.User do
  @moduledoc false
  # User and account endpoints. See `Authmk.Endpoints`.

  alias Authmk.{
    Background,
    CookieCache,
    Cookies,
    Credentials,
    Email,
    EmailVerification,
    Error,
    Input,
    Origin,
    Serializer,
    Sessions,
    Store,
    URL,
    Verification
  }

  @delete_purpose "delete-account"
  @confirm_change_purpose "change-email-confirmation"

  def update_user(ctx) do
    with {:ok, user} <- Store.update(ctx, :user, ctx.user, Input.attrs(ctx, :user), :internal) do
      ctx = CookieCache.put(%{ctx | user: user}, Cookies.remember_me?(ctx))
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  def change_email(%{config: config, user: user} = ctx) do
    new_email = Email.normalize(ctx.params.new_email)
    callback_url = ctx.params.callback_url

    with :ok <- enabled(config.user[:change_email][:enabled]),
         :ok <- Origin.check_redirect(ctx, callback_url),
         :ok <- valid_email(new_email) do
      cond do
        # Same answer as a change that goes ahead, so this can't find
        # registered emails. Nothing changes and nothing is sent.
        email_available(ctx, new_email) != :ok -> {:ok, %{status: true}, ctx}
        user.email_verified -> change_verified_email(ctx, new_email, callback_url)
        true -> change_unverified_email(ctx, new_email, callback_url)
      end
    end
  end

  def delete_user(%{config: config} = ctx) do
    with :ok <- enabled(config.user[:delete_user][:enabled]),
         :ok <- Origin.check_redirect(ctx, ctx.params.callback_url),
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
         :ok <- Origin.check_redirect(ctx, params.callback_url),
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

  # Opened from the current address: now the new address gets its link.
  def confirm_email_change(%{params: params} = ctx) do
    with :ok <- Origin.check_redirect(ctx, params.callback_url),
         {:ok, data} <- Verification.consume(ctx, @confirm_change_purpose, params.token),
         %{} = user <- Store.get_by(ctx, :user, id: data["user_id"]),
         :ok <- email_available(ctx, data["new_email"]),
         :ok <-
           EmailVerification.send_change_email(ctx, user, data["new_email"], params.callback_url) do
      if params.callback_url,
        do: {:redirect, params.callback_url, ctx},
        else: {:ok, %{status: true}, ctx}
    else
      nil -> {:error, Error.new(:invalid_token)}
      error -> error
    end
  end

  # A verified address only changes once the new one confirms, and, with
  # `confirm_current_email`, once the current one approves first.
  defp change_verified_email(ctx, new_email, callback_url) do
    result =
      if ctx.config.user[:change_email][:confirm_current_email],
        do: send_change_confirmation(ctx, new_email, callback_url),
        else: EmailVerification.send_change_email(ctx, ctx.user, new_email, callback_url)

    with :ok <- result, do: {:ok, %{status: true}, ctx}
  end

  defp send_change_confirmation(%{config: config, user: user} = ctx, new_email, callback_url) do
    data = %{"user_id" => to_string(user.id), "new_email" => new_email}
    expires_in = config.email_verification[:expires_in]

    with {:ok, token} <- Verification.create(ctx, @confirm_change_purpose, data, expires_in) do
      url =
        URL.endpoint(ctx, "/change-email/confirm", token: token, callback_url: callback_url)

      link = %{user: user, new_email: new_email, url: url, token: token}
      Background.callback(ctx, :send_change_email_confirmation, link)
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
        URL.endpoint(ctx, "/delete-user/callback",
          token: token,
          callback_url: ctx.params.callback_url
        )

      Background.callback(ctx, :send_delete_account_verification, %{
        user: user,
        url: url,
        token: token
      })

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
