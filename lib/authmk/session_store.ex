defmodule Authmk.SessionStore do
  @moduledoc """
  Where sessions live.

    * No secondary storage: the database.
    * Secondary storage: only there, by default. Each entry holds the session
      and its user, so loading a session needs no database query.
    * Secondary storage with `session: [store_in_database: true]`: both.
      Lookups try secondary storage first, then the database.

  With `session: [preserve_in_database: true]`, revoking keeps the database
  row and marks it ended (`expires_at` set to now) instead of deleting it.

  In secondary storage, `session:<token hash>` holds a session, and
  `active-sessions:<user id>` lists a user's sessions so they can be listed
  and revoked.
  """

  import Ecto.Query

  alias Authmk.{Context, Error, Hooks, Storage, Store}
  alias Authmk.Schema.{Changeset, Definition}

  @doc "Creates a session for `user` from internal `attrs`."
  @spec insert(Context.t(), map(), struct()) :: {:ok, struct()} | {:error, Error.t()}
  def insert(ctx, attrs, user) do
    case mode(ctx) do
      :database ->
        Store.insert(ctx, :session, attrs)

      :secondary ->
        with {:ok, attrs} <- Hooks.before_write(:before_create, :session, attrs, ctx),
             {:ok, session} <- build(ctx, attrs) do
          cache(ctx, session, user)
          Hooks.after_write(:after_create, :session, session, ctx)
          {:ok, session}
        end

      :both ->
        with {:ok, session} <- Store.insert(ctx, :session, attrs) do
          cache(ctx, session, user)
          {:ok, session}
        end
    end
  end

  @doc "The session with this token hash, with its `user` loaded, or `nil`."
  @spec fetch(Context.t(), String.t()) :: struct() | nil
  def fetch(ctx, token_hash) do
    case mode(ctx) do
      :database -> fetch_from_database(ctx, token_hash)
      :secondary -> fetch_cached(ctx, token_hash)
      :both -> fetch_cached(ctx, token_hash) || fetch_from_database(ctx, token_hash)
    end
  end

  @doc "Updates a session (with its `user` loaded) with internal `attrs`."
  @spec update(Context.t(), struct(), map()) :: {:ok, struct()} | {:error, Error.t()}
  def update(ctx, session, attrs) do
    result =
      case mode(ctx) do
        :secondary -> update_cached(ctx, session, attrs)
        _database -> Store.update(ctx, :session, session, attrs)
      end

    with {:ok, updated} <- result do
      if mode(ctx) != :database, do: cache(ctx, updated, session.user)
      {:ok, updated}
    end
  end

  @doc "Active sessions of a user, newest first."
  @spec list(Context.t(), term()) :: [struct()]
  def list(ctx, user_id) do
    case mode(ctx) do
      :database ->
        list_from_database(ctx, user_id)

      _cached ->
        ctx
        |> cached_hashes(user_id)
        |> Enum.map(&fetch_cached(ctx, &1))
        |> Enum.reject(&is_nil/1)
    end
  end

  @doc "Ends one session."
  @spec delete(Context.t(), struct()) :: :ok
  def delete(ctx, session), do: delete_by_id(ctx, session.user_id, session.id)

  @doc "Ends one of the user's sessions, by id. Other users' sessions are untouched."
  @spec delete_by_id(Context.t(), term(), term()) :: :ok
  def delete_by_id(ctx, user_id, id) do
    end_sessions(ctx, user_id, &(to_string(&1.id) == to_string(id)), dynamic([s], s.id == ^id))
  end

  @doc "Ends every session of the user."
  @spec delete_all(Context.t(), term()) :: :ok
  def delete_all(ctx, user_id), do: end_sessions(ctx, user_id, fn _ -> true end, dynamic(true))

  @doc "Ends every session of the user except `keep_id`."
  @spec delete_others(Context.t(), term(), term()) :: :ok
  def delete_others(ctx, user_id, keep_id) do
    end_sessions(ctx, user_id, &(&1.id != keep_id), dynamic([s], s.id != ^keep_id))
  end

  # Cached sessions are filtered with `cached?`; database rows with the
  # `database` condition, in one query, so no listing limit applies.
  defp end_sessions(ctx, user_id, cached?, database) do
    :ok = end_cached(ctx, mode(ctx), user_id, cached?)
    :ok = end_stored(ctx, mode(ctx), user_id, database)
  end

  defp end_cached(_ctx, :database, _user_id, _cached?), do: :ok

  defp end_cached(ctx, _mode, user_id, cached?) do
    ctx |> list(user_id) |> Enum.filter(cached?) |> Enum.each(&uncache(ctx, &1))
  end

  defp end_stored(_ctx, :secondary, _user_id, _database), do: :ok

  defp end_stored(ctx, _mode, user_id, database) do
    _count = end_in_database(ctx, dynamic([s], s.user_id == ^user_id and ^database))
    :ok
  end

  @doc "Rewrites the user in every cached session, after the user changed."
  @spec refresh_user(Context.t(), struct()) :: :ok
  def refresh_user(ctx, user) do
    if mode(ctx) != :database do
      Enum.each(list(ctx, user.id), &cache(ctx, &1, user))
    end

    :ok
  end

  @doc "Drops every cached session of a deleted user."
  @spec forget_user(Context.t(), term()) :: :ok
  def forget_user(ctx, user_id) do
    if mode(ctx) != :database do
      ctx |> cached_hashes(user_id) |> Enum.each(&Storage.delete(ctx.config, session_key(&1)))
      Storage.delete(ctx.config, list_key(user_id))
    end

    :ok
  end

  defp mode(%Context{config: config}) do
    cond do
      not Storage.configured?(config) -> :database
      config.session[:store_in_database] -> :both
      true -> :secondary
    end
  end

  defp fetch_from_database(ctx, token_hash) do
    query =
      from session in Store.module(ctx, :session),
        join: user in assoc(session, :user),
        where: session.token == ^token_hash,
        preload: [user: user]

    Store.one(ctx, :session, query)
  end

  defp list_from_database(ctx, user_id) do
    now = DateTime.utc_now()
    Store.all(ctx, :session, dynamic([s], s.user_id == ^user_id and s.expires_at > ^now))
  end

  defp end_in_database(%Context{config: config} = ctx, condition) do
    if config.session[:preserve_in_database] do
      now = DateTime.utc_now()
      still_live = dynamic([s], ^condition and s.expires_at > ^now)
      query = from(s in Store.module(ctx, :session), where: ^still_live)
      Store.update_all(ctx, :session, query, set: [expires_at: now])
    else
      Store.delete_all(ctx, :session, condition)
    end
  end

  # A session that only lives in secondary storage: validated like a
  # database insert, with an id and timestamps.
  defp build(ctx, attrs) do
    module = Store.module(ctx, :session)
    now = DateTime.utc_now()

    ctx.config.schema
    |> Definition.model!(:session)
    |> Changeset.build(struct(module), attrs, :internal)
    |> Ecto.Changeset.change(id: Ecto.UUID.generate(), inserted_at: now, updated_at: now)
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, session} -> {:ok, session}
      {:error, changeset} -> {:error, Error.from_changeset(changeset)}
    end
  end

  defp update_cached(ctx, session, attrs) do
    ctx.config.schema
    |> Definition.model!(:session)
    |> Changeset.build(session, attrs, :internal)
    |> Ecto.Changeset.change(updated_at: DateTime.utc_now())
    |> Ecto.Changeset.apply_action(:update)
    |> case do
      {:ok, session} -> {:ok, session}
      {:error, changeset} -> {:error, Error.from_changeset(changeset)}
    end
  end

  defp cache(%Context{config: config}, session, user) do
    ttl = ttl(session.expires_at)
    entry = %{"session" => dump(session), "user" => dump(user)}
    :ok = Storage.put(config, session_key(session.token), JSON.encode!(entry), ttl)
    track(config, session.user_id, session.token, session.expires_at)
  end

  defp fetch_cached(%Context{config: config} = ctx, token_hash) do
    with value when is_binary(value) <- Storage.get(config, session_key(token_hash)),
         {:ok, %{"session" => session, "user" => user}} <- JSON.decode(value) do
      session = Ecto.embedded_load(Store.module(ctx, :session), session, :json)
      %{session | user: Ecto.embedded_load(Store.module(ctx, :user), user, :json)}
    else
      _ -> nil
    end
  end

  defp uncache(%Context{config: config} = ctx, session) do
    if mode(ctx) != :database do
      :ok = Storage.delete(config, session_key(session.token))
      untrack(config, session.user_id, session.token)
    end
  end

  # The user's session list. Read-modify-write: two sign-ins at the same
  # moment may lose one list entry; that session then can't be listed, but
  # still works and still expires.
  defp track(config, user_id, token_hash, expires_at) do
    entries = [
      %{"hash" => token_hash, "expires_at" => DateTime.to_unix(expires_at)}
      | tracked(config, user_id)
    ]

    save_tracked(config, user_id, Enum.uniq_by(entries, & &1["hash"]))
  end

  defp untrack(config, user_id, token_hash) do
    entries = Enum.reject(tracked(config, user_id), &(&1["hash"] == token_hash))
    save_tracked(config, user_id, entries)
  end

  defp save_tracked(config, user_id, entries) do
    now = System.system_time(:second)

    case Enum.filter(entries, &(&1["expires_at"] > now)) do
      [] ->
        Storage.delete(config, list_key(user_id))

      live ->
        ttl = Enum.max_by(live, & &1["expires_at"])["expires_at"] - now
        Storage.put(config, list_key(user_id), JSON.encode!(live), ttl)
    end
  end

  defp tracked(config, user_id) do
    with value when is_binary(value) <- Storage.get(config, list_key(user_id)),
         {:ok, entries} when is_list(entries) <- JSON.decode(value) do
      entries
    else
      _ -> []
    end
  end

  defp cached_hashes(%Context{config: config}, user_id) do
    config
    |> tracked(user_id)
    |> Enum.sort_by(& &1["expires_at"], :desc)
    |> Enum.map(& &1["hash"])
  end

  defp dump(struct), do: Ecto.embedded_dump(struct, :json)

  defp ttl(expires_at), do: max(DateTime.diff(expires_at, DateTime.utc_now()), 1)

  defp session_key(token_hash), do: "session:" <> token_hash
  defp list_key(user_id), do: "active-sessions:#{user_id}"
end
