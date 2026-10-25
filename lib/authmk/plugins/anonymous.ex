defmodule Authmk.Plugins.Anonymous do
  @moduledoc """
  Anonymous users: let visitors use the app before they sign up, and keep
  what they did when they do.

      use Authmk,
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.Anonymous, on_link_account: &MyApp.Carts.move_to_user/2}
        ],
        ...

  `POST /sign-in/anonymous` creates a user with `is_anonymous: true`, a
  generated email and name, and signs them in.

  When an anonymous user later signs in or up for real, with any method,
  `on_link_account` gets both users so the app can move their data, and the
  anonymous user is deleted (unless `disable_delete_anonymous_user: true`).

  | Method | Path | Session |
  |---|---|---|
  | POST | `/sign-in/anonymous` | optional (anonymous users can't sign in anonymously again) |

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.Anonymous.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{Context, Endpoint, Error, Log, Serializer, Sessions, SessionStore, Store, Token}
  alias Authmk.Cookies
  alias Authmk.Plugins.Anonymous.Options

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def schema(_opts) do
    %{user: [fields: [is_anonymous: [type: :boolean, default: false, input: false]]]}
  end

  @impl true
  def endpoints(_opts) do
    [
      Endpoint.new(
        name: :sign_in_anonymous,
        method: :post,
        path: "/sign-in/anonymous",
        handler: {__MODULE__, :sign_in},
        session: :optional,
        rate_limit: [window: 60, max: 10]
      )
    ]
  end

  @doc false
  def sign_in(%Context{user: %{is_anonymous: true}}),
    do: {:error, Error.custom(:already_anonymous, 400, "You are already signed in anonymously")}

  def sign_in(ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    attrs = %{
      email: email(ctx, opts),
      name: if(opts[:generate_name], do: opts[:generate_name].(), else: "Anonymous"),
      is_anonymous: true
    }

    with {:ok, user} <- Store.insert(ctx, :user, attrs) do
      case Sessions.sign_in(ctx, user) do
        {:ok, ctx} -> {:ok, %{user: Serializer.user(ctx, user)}, ctx}
        {:challenge, body, ctx} -> {:ok, body, ctx}
        {:error, error} -> {:error, error}
      end
    end
  end

  # Any request that replaced an anonymous user's session with another
  # user's links the two.
  @impl true
  def after_endpoint(_endpoint, ctx, {:ok, _body, new_ctx} = result),
    do: link(ctx, new_ctx, result)

  def after_endpoint(_endpoint, ctx, {:redirect, _url, new_ctx} = result),
    do: link(ctx, new_ctx, result)

  def after_endpoint(_endpoint, _ctx, result), do: result

  defp link(ctx, %Context{session: %{} = session, user: %{} = new_user}, result) do
    with true <- new_session?(ctx, session),
         %{is_anonymous: true} = anonymous_user <- previous_user(ctx),
         true <- anonymous_user.id != new_user.id do
      opts = Context.plugin_opts(ctx, __MODULE__)

      if opts[:on_link_account],
        do: opts[:on_link_account].(%{anonymous_user: anonymous_user, new_user: new_user}, ctx)

      unless opts[:disable_delete_anonymous_user], do: delete(ctx, anonymous_user)
    end

    result
  end

  defp link(_ctx, _new_ctx, result), do: result

  defp new_session?(%Context{session: nil}, _session), do: true
  defp new_session?(%Context{session: previous}, session), do: previous.id != session.id

  # The user of the session the request came with.
  defp previous_user(ctx) do
    with {:ok, token} <- Cookies.session_token(ctx),
         %{} = session <- SessionStore.fetch(ctx, Token.hash(token)) do
      session.user
    else
      _none -> nil
    end
  end

  defp delete(ctx, anonymous_user) do
    case Store.delete(ctx, :user, anonymous_user) do
      {:ok, _user} ->
        :ok

      {:error, error} ->
        Log.warning("Couldn't delete anonymous user #{anonymous_user.id}: #{error.code}")
    end
  end

  defp email(%Context{base_url: base_url}, opts) do
    case opts[:generate_email] do
      nil ->
        domain = opts[:email_domain] || URI.parse(base_url || "").host || "localhost"
        "temp-#{Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)}@#{domain}"

      generate ->
        generate.()
    end
  end
end
