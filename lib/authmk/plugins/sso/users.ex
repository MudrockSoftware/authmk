defmodule Authmk.Plugins.SSO.Users do
  @moduledoc false
  # Which user an SSO sign-in is for: the app's choice (`resolve_user`), the
  # account linked before, an existing user at the provider's verified
  # domain, or a new user. New users join the provider's organization.

  alias Authmk.{Context, Email, Error, Store}
  alias Authmk.Plugins.{Organization, SCIM}
  alias Authmk.Plugins.SSO.Config

  @doc "`{:ok, user, :existing | :new}` or `{:error, error}`."
  def resolve(ctx, provider, info, profile) do
    custom =
      case Config.opts(ctx)[:resolve_user] do
        nil -> :default
        resolve -> resolve.(profile, provider, ctx)
      end

    case custom do
      {:ok, user} -> {:ok, user, :existing}
      {:error, %Error{} = error} -> {:error, error}
      :default -> find_or_create(ctx, provider, info)
    end
  end

  defp find_or_create(ctx, provider, info) do
    email = info.email && Email.normalize(info.email)

    cond do
      user = linked(ctx, provider, info) ->
        {:ok, user, :existing}

      is_nil(email) ->
        {:error, Error.custom(:email_required, 400, "The identity provider sent no email")}

      user = Store.get_by(ctx, :user, email: email) ->
        link_existing(ctx, provider, user, info)

      Config.opts(ctx)[:disable_sign_up] ->
        {:error, Error.custom(:sign_up_disabled, 403, "Ask an admin for an account")}

      true ->
        create(ctx, provider, %{info | email: email})
    end
  end

  defp linked(ctx, provider, info) do
    with %{} = account <-
           Store.get_by(ctx, :account, provider_id: provider_key(provider), account_id: info.id) do
      Store.get_by(ctx, :user, id: account.user_id)
    end
  end

  # Only a provider that proved its domain may claim the users there: one
  # that didn't could take over any account by naming its email.
  defp link_existing(ctx, provider, user, info) do
    if owns_email?(ctx, provider, user.email) or provisioned?(ctx, provider, user) do
      with {:ok, _account} <- insert_account(ctx, provider, user, info),
           :ok <- join_organization(ctx, provider, user),
           do: {:ok, user, :existing}
    else
      {:error, Error.custom(:account_not_linked, 403, "Sign in the usual way, then connect SSO")}
    end
  end

  defp create(ctx, provider, info) do
    attrs = %{
      email: info.email,
      name: info.name || info.email |> String.split("@") |> hd(),
      image: info.image,
      # Only a verified domain vouches for its addresses. Anyone can add a
      # provider, so its own email_verified claim proves nothing: trusting
      # it would let it plant verified accounts for strangers' emails, which
      # other sign-in methods then link to.
      email_verified: owns_email?(ctx, provider, info.email)
    }

    result =
      Store.transaction(ctx, fn ->
        with {:ok, user} <- Store.insert(ctx, :user, attrs),
             {:ok, _account} <- insert_account(ctx, provider, user, info),
             do: {:ok, user}
      end)

    with {:ok, user} <- result,
         :ok <- join_organization(ctx, provider, user),
         do: {:ok, user, :new}
  end

  # A SCIM connection tied to this provider provisioned the user.
  defp provisioned?(%Context{config: config} = ctx, provider, user) do
    SCIM in Enum.map(config.plugins, &elem(&1, 0)) and
      SCIM.provisioned_for?(ctx, user, provider)
  end

  defp owns_email?(ctx, %{domain: domain} = provider, email) when is_binary(domain) do
    verified = provider.domain_verified or not Config.opts(ctx)[:domain_verification]
    verified and String.ends_with?(email, "@" <> domain)
  end

  defp owns_email?(_ctx, _provider, _email), do: false

  defp insert_account(ctx, provider, user, info),
    do:
      Store.insert(ctx, :account, %{
        user_id: user.id,
        provider_id: provider_key(provider),
        account_id: info.id
      })

  defp join_organization(%Context{config: config} = ctx, %{organization_id: org_id}, user)
       when is_binary(org_id) do
    if Organization in Enum.map(config.plugins, &elem(&1, 0)) do
      case Organization.add_member(
             config.auth,
             org_id,
             user.id,
             Config.opts(ctx)[:organization_role]
           ) do
        {:ok, _member} -> :ok
        {:error, %Error{code: :already_member}} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp join_organization(_ctx, _provider, _user), do: :ok

  @doc "Accounts from a provider are stored under this id."
  def provider_key(provider), do: "sso:" <> provider.provider_id
end
