defmodule Authmk.Credentials do
  @moduledoc """
  Password credentials. A user's password hash lives on their account row
  with `provider_id: "credential"`.
  """

  alias Authmk.{Context, Error, Store}

  @provider_id "credential"

  @doc "The provider id of password accounts."
  @spec provider_id() :: String.t()
  def provider_id, do: @provider_id

  @doc "The user's password account, or `nil`."
  @spec account(Context.t(), term()) :: struct() | nil
  def account(ctx, user_id),
    do: Store.get_by(ctx, :account, user_id: user_id, provider_id: @provider_id)

  @doc """
  Checks `password` against the user's password. Spends the same time when
  the user has no password, so timing reveals nothing.
  """
  @spec check_password(Context.t(), struct() | nil, String.t()) :: :ok | {:error, Error.t()}
  def check_password(%Context{config: config} = ctx, user, password) do
    hasher = config.password_hasher

    case user && account(ctx, user.id) do
      %{password: hash} when is_binary(hash) ->
        if hasher.verify(password, hash), do: :ok, else: {:error, Error.new(:invalid_password)}

      _no_password ->
        hasher.no_user_verify()
        {:error, Error.new(:invalid_password)}
    end
  end

  @doc "Sets the user's password, creating their password account when needed."
  @spec set_password(Context.t(), struct(), String.t()) :: {:ok, struct()} | {:error, Error.t()}
  def set_password(%Context{config: config} = ctx, user, password) do
    hash = config.password_hasher.hash(password)

    case account(ctx, user.id) do
      nil ->
        attrs = %{user_id: user.id, account_id: to_string(user.id), provider_id: @provider_id}
        Store.insert(ctx, :account, Map.put(attrs, :password, hash))

      account ->
        Store.update(ctx, :account, account, %{password: hash})
    end
  end
end
