defmodule Authmk.OAuth.Accounts do
  @moduledoc """
  Turns a provider's user into a local user and account.

  On sign-in:

    * An account already linked to this provider identity signs its user in,
      refreshing the stored tokens (`account: [update_account_on_sign_in: true]`).
    * Otherwise, an existing user with the same email gets the account linked
      only when linking is enabled, the provider verified the email (or is in
      `trusted_providers`), and the local email is verified too. Otherwise the
      sign-in fails with `account_not_linked`, so nobody can take over an
      account by registering its email elsewhere.
    * Otherwise a new user is created, unless sign-up is disabled.

  OAuth tokens are encrypted at rest with `account: [encrypt_oauth_tokens: true]`.
  """

  import Ecto.Query, only: [dynamic: 2]

  alias Authmk.{Context, Crypto, Email, Error, Store}
  alias Authmk.OAuth.{Provider, Tokens}

  @encrypted_prefix "enc:"

  @doc """
  Signs in with a provider's user. Returns the user and whether it is new.
  `opts`: `:request_sign_up` allows sign-up when the provider disables implicit sign-up.
  """
  @spec sign_in(Context.t(), Provider.t(), Provider.user_info(), Tokens.t(), keyword()) ::
          {:ok, struct(), :existing | :new} | {:error, Error.t()}
  def sign_in(ctx, %Provider{} = provider, info, %Tokens{} = tokens, opts \\ []) do
    with {:ok, info} <- normalize(info) do
      case find_account(ctx, provider.id, info.id) do
        nil -> sign_in_by_email(ctx, provider, info, tokens, opts)
        account -> sign_in_linked(ctx, provider, account, info, tokens)
      end
    end
  end

  @doc "Links a provider's user to `user`, for `POST /link-social`."
  @spec link(Context.t(), Provider.t(), struct(), Provider.user_info(), Tokens.t()) ::
          {:ok, struct()} | {:error, Error.t()}
  def link(%Context{config: config} = ctx, %Provider{} = provider, user, info, tokens) do
    with {:ok, info} <- normalize(info) do
      allow_different_emails = config.account[:account_linking][:allow_different_emails]

      case find_account(ctx, provider.id, info.id) do
        %{user_id: user_id} = account when user_id == user.id ->
          update_tokens(ctx, account, tokens)

        %{} ->
          {:error, Error.new(:account_already_linked_to_different_user)}

        nil when info.email != user.email and not allow_different_emails ->
          {:error, Error.new(:email_doesnt_match)}

        nil ->
          create_account(ctx, provider, user, info, tokens)
      end
    end
  end

  @doc "Reads a stored token, decrypting it when it was encrypted."
  @spec read_token(Context.t(), String.t() | nil) :: String.t() | nil
  def read_token(_ctx, nil), do: nil

  def read_token(%Context{config: config}, @encrypted_prefix <> encrypted) do
    case Crypto.decrypt(config, "oauth-token", encrypted) do
      {:ok, token} -> token
      :error -> nil
    end
  end

  def read_token(_ctx, token), do: token

  @doc """
  Stores new tokens on an account. Scopes granted before are kept: asking
  for more later doesn't lose them.
  """
  @spec update_tokens(Context.t(), struct(), Tokens.t()) :: {:ok, struct()} | {:error, Error.t()}
  def update_tokens(ctx, account, tokens) do
    attrs =
      ctx
      |> token_attrs(tokens)
      |> Map.update!(:scope, &merge_scopes(account.scope, &1))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Store.update(ctx, :account, account, attrs)
  end

  defp sign_in_linked(%Context{config: config} = ctx, provider, account, info, tokens) do
    user = Store.get_by(ctx, :user, id: account.user_id)

    with {:ok, _account} <-
           maybe_update_tokens(ctx, config.account[:update_account_on_sign_in], account, tokens),
         {:ok, user} <- maybe_override_user(ctx, provider, user, info),
         {:ok, user} <- maybe_mark_verified(ctx, user, info) do
      {:ok, user, :existing}
    end
  end

  defp sign_in_by_email(ctx, provider, info, tokens, opts) do
    case Store.get_by(ctx, :user, email: info.email) do
      nil -> sign_up(ctx, provider, info, tokens, opts)
      user -> link_by_email(ctx, provider, user, info, tokens)
    end
  end

  defp link_by_email(%Context{config: config} = ctx, provider, user, info, tokens) do
    linking = config.account[:account_linking]
    trusted? = provider.id in linking[:trusted_providers]
    local_verified? = user.email_verified or not linking[:require_local_email_verified]

    if linking[:enabled] and (trusted? or info.email_verified) and local_verified? do
      with {:ok, _account} <- create_account(ctx, provider, user, info, tokens),
           {:ok, user} <- maybe_mark_verified(ctx, user, info) do
        {:ok, user, :existing}
      end
    else
      {:error, Error.new(:account_not_linked)}
    end
  end

  defp sign_up(ctx, provider, info, tokens, opts) do
    implicit_off? =
      provider.options[:disable_implicit_sign_up] and
        not Keyword.get(opts, :request_sign_up, false)

    if provider.options[:disable_sign_up] or implicit_off? do
      {:error, Error.new(:sign_up_disabled)}
    else
      with {:ok, user} <- create_user_with_account(ctx, provider, info, tokens) do
        {:ok, user, :new}
      end
    end
  end

  defp create_user_with_account(ctx, provider, info, tokens) do
    Store.transaction(ctx, fn ->
      with {:ok, user} <- Store.insert(ctx, :user, new_user_attrs(info)),
           {:ok, _account} <- create_account(ctx, provider, user, info, tokens) do
        {:ok, user}
      end
    end)
  end

  defp new_user_attrs(info) do
    # Some providers share no name; the email's local part stands in.
    name = info.name || info.email |> String.split("@") |> hd()
    %{name: name, email: info.email, email_verified: info.email_verified, image: info.image}
  end

  defp create_account(ctx, provider, user, info, tokens) do
    attrs =
      Map.merge(token_attrs(ctx, tokens), %{
        user_id: user.id,
        provider_id: Atom.to_string(provider.id),
        account_id: info.id
      })

    Store.insert(ctx, :account, attrs)
  end

  defp merge_scopes(old, nil), do: old
  defp merge_scopes(nil, new), do: new

  defp merge_scopes(old, new),
    do: Enum.join(Enum.uniq(String.split(old, ",") ++ String.split(new, ",")), ",")

  defp maybe_update_tokens(ctx, true, account, tokens), do: update_tokens(ctx, account, tokens)
  defp maybe_update_tokens(_ctx, false, account, _tokens), do: {:ok, account}

  # With `override_user_info_on_sign_in`, the provider's name and image win.
  defp maybe_override_user(ctx, provider, user, info) do
    if provider.options[:override_user_info_on_sign_in] do
      attrs = %{name: info.name || user.name, image: info.image || user.image}
      Store.update(ctx, :user, user, attrs)
    else
      {:ok, user}
    end
  end

  # A provider that verified the same address proves it for us too.
  defp maybe_mark_verified(ctx, user, info) do
    if info.email_verified and not user.email_verified and info.email == user.email,
      do: Store.update(ctx, :user, user, %{email_verified: true}),
      else: {:ok, user}
  end

  defp token_attrs(%Context{config: config} = ctx, tokens) do
    attrs = Tokens.account_attrs(tokens)

    if config.account[:encrypt_oauth_tokens],
      do: %{
        attrs
        | access_token: encrypt(ctx, attrs.access_token),
          refresh_token: encrypt(ctx, attrs.refresh_token)
      },
      else: attrs
  end

  defp encrypt(_ctx, nil), do: nil

  defp encrypt(%Context{config: config}, token),
    do: @encrypted_prefix <> Crypto.encrypt(config, "oauth-token", token)

  defp find_account(ctx, provider_id, account_id) do
    provider_id = Atom.to_string(provider_id)

    ctx
    |> Store.all(
      :account,
      dynamic([a], a.provider_id == ^provider_id and a.account_id == ^account_id),
      limit: 1
    )
    |> List.first()
  end

  defp normalize(%{id: id}) when id in [nil, ""],
    do: {:error, Error.new(:unable_to_get_user_info)}

  defp normalize(%{id: id, email: email} = info) when is_binary(email) and email != "" do
    {:ok,
     %{
       info
       | id: to_string(id),
         email: Email.normalize(email),
         email_verified: info.email_verified == true
     }}
  end

  defp normalize(_info), do: {:error, Error.new(:email_not_found)}
end
