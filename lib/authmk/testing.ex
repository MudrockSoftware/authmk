defmodule Authmk.Testing do
  @moduledoc """
  Helpers for your app's tests: create users and sessions without going
  through the sign-up and sign-in endpoints, and sign a test conn in.

      test "the account page shows the user", %{conn: conn} do
        user = Authmk.Testing.create_user(MyApp.Auth, email: "ada@example.com", password: "correct horse")
        conn = conn |> Authmk.Testing.sign_in(MyApp.Auth, user) |> get("/account")
        assert html_response(conn, 200) =~ "ada@example.com"
      end

  Records are written with your auth module's repo, so they follow your
  test's Ecto sandbox, and database hooks run as they would in the app.
  Only use this module in tests.

  For the codes and links authmk sends, see `Authmk.Testing.Inbox`.
  """

  alias Authmk.{BaseURL, Context, Credentials, Email, Error, Sessions, Store}

  @doc """
  Creates a user. `attrs` are user fields, plus `:password` to give them a
  password they can sign in with. Defaults: a unique email, the name
  `"Test User"`, and a verified email.
  """
  @spec create_user(module(), map() | keyword()) :: struct()
  def create_user(auth, attrs \\ %{}) do
    ctx = Context.new(auth.config())
    {password, attrs} = attrs |> Map.new() |> Map.pop(:password)

    attrs =
      Map.merge(
        %{
          email: "user-#{System.unique_integer([:positive])}@example.com",
          name: "Test User",
          email_verified: true
        },
        attrs
      )

    result =
      Store.transaction(ctx, fn ->
        with {:ok, user} <-
               Store.insert(ctx, :user, %{attrs | email: Email.normalize(attrs.email)}),
             :ok <- maybe_set_password(ctx, user, password) do
          {:ok, user}
        end
      end)

    case result do
      {:ok, user} -> user
      {:error, error} -> raise ArgumentError, "couldn't create the user: #{describe(error)}"
    end
  end

  defp maybe_set_password(_ctx, _user, nil), do: :ok

  defp maybe_set_password(ctx, user, password) do
    with {:ok, _account} <- Credentials.set_password(ctx, user, password), do: :ok
  end

  @doc """
  Creates a session for `user`. Returns the session and the cookies a
  browser would hold for it (name => value).

  Options: `:remember_me` (default `true`), `:base_url` (default the auth
  module's), which decides the cookies' names.
  """
  @spec create_session(module(), struct(), keyword()) :: %{
          session: struct(),
          cookies: %{String.t() => String.t()}
        }
  def create_session(auth, user, opts \\ []) do
    config = auth.config()
    ctx = %{Context.new(config) | base_url: opts[:base_url] || static_base_url(config)}

    case Sessions.create(ctx, user, Keyword.get(opts, :remember_me, true)) do
      {:ok, ctx} -> %{session: ctx.session, cookies: cookies(ctx)}
      {:error, error} -> raise ArgumentError, "couldn't create the session: #{describe(error)}"
    end
  end

  @doc """
  Signs `user` in on a test conn (`Plug.Test` or `Phoenix.ConnTest`): a new
  session, with its cookies on the request. Takes the options of
  `create_session/3`.
  """
  @spec sign_in(Plug.Conn.t(), module(), struct(), keyword()) :: Plug.Conn.t()
  def sign_in(%Plug.Conn{} = conn, auth, user, opts \\ []) do
    base_url = opts[:base_url] || request_base_url(auth.config(), conn)
    %{cookies: cookies} = create_session(auth, user, Keyword.put(opts, :base_url, base_url))

    Enum.reduce(cookies, conn, fn {name, value}, conn ->
      Plug.Test.put_req_cookie(conn, name, value)
    end)
  end

  @doc "The user matching `clauses` (like `email: \"ada@example.com\"`), or `nil`."
  @spec get_user_by(module(), keyword()) :: struct() | nil
  def get_user_by(auth, clauses) do
    clauses =
      Keyword.new(clauses, fn
        {:email, email} -> {:email, Email.normalize(email)}
        other -> other
      end)

    auth.config() |> Context.new() |> Store.get_by(:user, clauses)
  end

  @doc "The user's sessions."
  @spec list_sessions(module(), struct()) :: [struct()]
  def list_sessions(auth, user), do: auth.config() |> Context.new() |> Sessions.list(user.id)

  defp cookies(%Context{resp_cookies: cookies}),
    do: for({name, value, _opts} <- cookies, is_binary(value), into: %{}, do: {name, value})

  defp static_base_url(config) do
    case BaseURL.resolve(config, nil) do
      {:ok, base_url} -> base_url
      _dynamic -> nil
    end
  end

  defp request_base_url(config, conn) do
    case BaseURL.resolve(config, conn) do
      {:ok, base_url} -> base_url
      _not_allowed -> static_base_url(config)
    end
  end

  defp describe(%Error{code: code, message: message}), do: "#{code}: #{message}"
  defp describe(other), do: inspect(other)
end
