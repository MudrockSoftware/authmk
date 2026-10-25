defmodule Authmk.Verification do
  @moduledoc """
  Single-use tokens for email links: email verification, password reset,
  email change and account deletion.

  Each token is stored under `"<purpose>:<SHA-256 of the token>"` with a JSON
  payload; the token itself is only sent to the user. Tokens live in the
  database, or in secondary storage when one is configured (with
  `verification: [store_in_database: true]` to keep database copies too).

  Using a token up is atomic, so two requests racing with the same token
  can't both succeed.
  """

  import Ecto.Query, only: [dynamic: 2]

  alias Authmk.{Context, Error, Storage, Store, Token}

  @doc "Creates a token for `purpose` carrying `data`. Returns the token."
  @spec create(Context.t(), String.t(), map(), pos_integer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def create(ctx, purpose, data, expires_in) do
    token = Token.generate()
    identifier = identifier(purpose, token)
    value = JSON.encode!(data)
    expires_at = DateTime.add(DateTime.utc_now(), expires_in)

    with :ok <- create_in_database(ctx, identifier, value, expires_at) do
      if cached?(ctx), do: Storage.put(ctx.config, key(identifier), value, expires_in)
      {:ok, token}
    end
  end

  @doc "Reads a token's data without using it up."
  @spec peek(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def peek(ctx, purpose, token) when is_binary(token) do
    identifier = identifier(purpose, token)

    cached_value =
      if cached?(ctx), do: Storage.get(ctx.config, key(identifier))

    case cached_value || database_value(ctx, identifier) do
      nil -> invalid_token()
      value -> {:ok, JSON.decode!(value)}
    end
  end

  def peek(_ctx, _purpose, _token), do: invalid_token()

  @doc "Reads a token's data and deletes it, so it works only once."
  @spec consume(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def consume(ctx, purpose, token) when is_binary(token) do
    identifier = identifier(purpose, token)

    result =
      cond do
        not cached?(ctx) -> consume_from_database(ctx, identifier)
        value = Storage.get_and_delete(ctx.config, key(identifier)) -> {:ok, value}
        true -> invalid_token()
      end

    :ok = drop_database_copy(ctx, identifier)

    with {:ok, value} <- result, do: {:ok, JSON.decode!(value)}
  end

  def consume(_ctx, _purpose, _token), do: invalid_token()

  defp create_in_database(ctx, identifier, value, expires_at) do
    if in_database?(ctx) do
      attrs = %{identifier: identifier, value: value, expires_at: expires_at}
      with {:ok, _verification} <- Store.insert(ctx, :verification, attrs), do: :ok
    else
      :ok
    end
  end

  defp database_value(ctx, identifier) do
    case live_row(ctx, identifier) do
      nil -> nil
      verification -> verification.value
    end
  end

  # Deleting by id and checking the count makes the database path atomic:
  # only one request can delete the row.
  defp consume_from_database(ctx, identifier) do
    with %{} = verification <- live_row(ctx, identifier),
         1 <- Store.delete_all(ctx, :verification, id: verification.id) do
      {:ok, verification.value}
    else
      _ -> invalid_token()
    end
  end

  # With copies in both places, using a token removes the database copy too.
  defp drop_database_copy(ctx, identifier) do
    if cached?(ctx) and in_database?(ctx) do
      _count = Store.delete_all(ctx, :verification, identifier: identifier)
      :ok
    else
      :ok
    end
  end

  defp live_row(ctx, identifier) do
    now = DateTime.utc_now()
    condition = dynamic([v], v.identifier == ^identifier and v.expires_at > ^now)
    ctx |> Store.all(:verification, condition, limit: 1) |> List.first()
  end

  defp cached?(%Context{config: config}), do: Storage.configured?(config)

  defp in_database?(%Context{config: config}),
    do: not Storage.configured?(config) or config.verification[:store_in_database]

  defp identifier(purpose, token), do: "#{purpose}:#{Token.hash(token)}"

  defp key(identifier), do: "verification:" <> identifier

  defp invalid_token, do: {:error, Error.new(:invalid_token)}
end
