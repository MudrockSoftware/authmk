defmodule Authmk.Plugins.Username do
  @moduledoc """
  Usernames: sign up with one, sign in with it and a password, change it.

      use Authmk,
        plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.Username, min_length: 3}],
        ...

  Users get a `username` (unique, normalized: lowercase by default) and a
  `display_username` (as typed, unless you normalize it too). Clients set
  them like other user fields: in `POST /sign-up/email` and
  `POST /update-user`. A display username defaults to the username as typed.

  | Method | Path | Session |
  |---|---|---|
  | POST | `/sign-in/username` | none |
  | POST | `/is-username-available` | none (unless `disable_availability_check`) |

  Signing in with a username works like signing in with an email (see
  `Authmk.Plugins.EmailPassword`): wrong usernames and wrong passwords fail
  the same way, and two-factor authentication applies.

  The availability check tells anyone whether a username exists. Turn it off
  with `disable_availability_check: true` if that matters to you; sign-up
  still refuses taken usernames.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.Username.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{Context, Endpoint, Error, Store}
  alias Authmk.Plugins.EmailPassword
  alias Authmk.Plugins.Username.Options

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def depends_on, do: [EmailPassword]

  @impl true
  def schema(_opts) do
    %{
      user: [
        fields: [
          username: [type: :string, unique: true],
          display_username: [type: :string]
        ]
      ]
    }
  end

  @impl true
  def endpoints(opts) do
    sign_in =
      Endpoint.new(
        name: :sign_in_username,
        method: :post,
        path: "/sign-in/username",
        handler: {__MODULE__, :sign_in},
        rate_limit: [window: 10, max: 3],
        params: [
          username: [type: :string, required: true],
          password: [type: :string, required: true],
          callback_url: [type: :string],
          remember_me: [type: :boolean, default: true]
        ]
      )

    available =
      Endpoint.new(
        name: :is_username_available,
        method: :post,
        path: "/is-username-available",
        handler: {__MODULE__, :available},
        rate_limit: [window: 10, max: 10],
        params: [username: [type: :string, required: true]]
      )

    if opts[:disable_availability_check], do: [sign_in], else: [sign_in, available]
  end

  @impl true
  def database_hook(:before_create, :user, attrs, ctx), do: check_attrs(attrs, nil, ctx)

  def database_hook(:before_update, :user, attrs, ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    current = ctx.user

    if (opts[:immutable] and current) && current.username && changes_username?(attrs, current),
      do: {:error, error(:username_immutable)},
      else: check_attrs(attrs, current, ctx)
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  @doc false
  # Unknown and invalid usernames fail like wrong passwords.
  def sign_in(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    username = opts[:normalizer].(params.username)
    EmailPassword.password_sign_in(ctx, Store.get_by(ctx, :user, username: username))
  end

  @doc false
  def available(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    username = opts[:normalizer].(params.username)

    with :ok <- validate(username, opts) do
      {:ok, %{available: is_nil(Store.get_by(ctx, :user, username: username))}, ctx}
    end
  end

  # Validates and normalizes the username and display username in `attrs`,
  # which have string keys (request input) or atom keys (authmk's own writes).
  defp check_attrs(attrs, current, ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with {:ok, attrs} <- check_username(attrs, current, ctx, opts) do
      check_display_username(attrs, opts)
    end
  end

  defp check_username(attrs, current, ctx, opts) do
    case fetch(attrs, :username) do
      {key, typed} when is_binary(typed) ->
        username = opts[:normalizer].(typed)

        with :ok <- validate(username, opts),
             :ok <- not_taken(ctx, username, current) do
          {:ok, attrs |> Map.put(key, username) |> put_new_display(typed)}
        end

      _no_username ->
        {:ok, attrs}
    end
  end

  defp check_display_username(attrs, opts) do
    case fetch(attrs, :display_username) do
      {key, display} when is_binary(display) ->
        display = opts[:display_username_normalizer].(display)

        if opts[:display_username_validator].(display),
          do: {:ok, Map.put(attrs, key, display)},
          else: {:error, error(:invalid_display_username)}

      _no_display_username ->
        {:ok, attrs}
    end
  end

  defp validate(username, opts) do
    length = String.length(username)

    cond do
      length < opts[:min_length] -> {:error, error(:username_too_short)}
      length > opts[:max_length] -> {:error, error(:username_too_long)}
      not opts[:validator].(username) -> {:error, error(:invalid_username)}
      true -> :ok
    end
  end

  defp not_taken(ctx, username, current) do
    case Store.get_by(ctx, :user, username: username) do
      nil -> :ok
      %{id: id} when not is_nil(current) and id == current.id -> :ok
      _someone_else -> {:error, error(:username_taken)}
    end
  end

  # The display username is the username as typed, unless one was given.
  defp put_new_display(attrs, typed) do
    case fetch(attrs, :display_username) do
      {_key, display} when is_binary(display) -> attrs
      _none -> Map.put(attrs, key_like(attrs, :display_username), typed)
    end
  end

  defp changes_username?(attrs, current) do
    case fetch(attrs, :username) do
      {_key, username} when is_binary(username) -> username != current.username
      _no_username -> false
    end
  end

  defp fetch(attrs, name) do
    cond do
      Map.has_key?(attrs, name) ->
        {name, attrs[name]}

      Map.has_key?(attrs, Atom.to_string(name)) ->
        {Atom.to_string(name), attrs[Atom.to_string(name)]}

      true ->
        nil
    end
  end

  # String keys unless the map uses atom keys.
  defp key_like(attrs, name) do
    if Enum.any?(Map.keys(attrs), &is_atom/1), do: name, else: Atom.to_string(name)
  end

  @errors %{
    username_taken: {422, "This username is taken"},
    username_too_short: {422, "This username is too short"},
    username_too_long: {422, "This username is too long"},
    invalid_username: {422, "Usernames may only contain letters, numbers, dots and underscores"},
    invalid_display_username: {422, "This display username isn't allowed"},
    username_immutable: {403, "Usernames can't be changed"}
  }

  defp error(code) do
    {status, message} = Map.fetch!(@errors, code)
    Error.custom(code, status, message)
  end
end
