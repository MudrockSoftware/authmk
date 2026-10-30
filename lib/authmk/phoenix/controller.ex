defmodule Authmk.Phoenix.Controller do
  @moduledoc """
  Helpers for controllers (Phoenix or plain Plug), after
  `Authmk.Plug.FetchSession`.

      import Authmk.Phoenix.Controller

      def show(conn, _params) do
        render(conn, :show, user: current_user(conn))
      end

      def delete(conn, _params) do
        conn |> sign_out(MyApp.Auth) |> redirect(to: ~p"/")
      end
  """

  alias Authmk.{ConnContext, Cookies, Error, Router, Sessions, SessionStore}

  @doc "The signed-in user, or `nil`."
  @spec current_user(Plug.Conn.t()) :: struct() | nil
  def current_user(conn), do: conn.assigns[:current_user]

  @doc "The signed-in session, or `nil`."
  @spec current_session(Plug.Conn.t()) :: struct() | nil
  def current_session(conn), do: conn.assigns[:current_session]

  @doc "The user, or the service account (or other principal) behind the request."
  @spec current_principal(Plug.Conn.t()) :: struct() | nil
  def current_principal(conn), do: conn.assigns[:current_principal]

  @doc "Whether a user is signed in."
  @spec signed_in?(Plug.Conn.t()) :: boolean()
  def signed_in?(conn), do: not is_nil(current_user(conn))

  @doc """
  Signs `user` in from your own code, like after a flow of yours that
  proved who they are, with the same checks as authmk's sign-ins (a second
  factor, plugins' rules). Returns the conn with the session cookie set,
  `{:challenge, conn, body}` when a second factor is due (body as the
  sign-in endpoints answer), or `{:error, error}`.
  """
  @spec sign_in(Plug.Conn.t(), module(), struct(), keyword()) ::
          {:ok, Plug.Conn.t()} | {:challenge, Plug.Conn.t(), map()} | {:error, Error.t()}
  def sign_in(conn, auth, user, opts \\ []) do
    with {:ok, ctx} <- context(conn, auth) do
      case Sessions.sign_in(ctx, user, Keyword.get(opts, :remember_me, true)) do
        {:ok, ctx} -> {:ok, signed_in(conn, ctx)}
        {:challenge, body, ctx} -> {:challenge, Router.put_resp_cookies(conn, ctx), body}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp signed_in(conn, ctx) do
    conn
    |> Router.put_resp_cookies(ctx)
    |> Plug.Conn.assign(:current_user, ctx.user)
    |> Plug.Conn.assign(:current_session, ctx.session)
    |> Plug.Conn.assign(:current_principal, ctx.user)
  end

  @doc "Ends the request's session (in the store, not only the cookie) and clears its cookies."
  @spec sign_out(Plug.Conn.t(), module()) :: Plug.Conn.t()
  def sign_out(conn, auth) do
    case context(conn, auth) do
      {:ok, ctx} ->
        ctx = Sessions.load(ctx)
        if ctx.session, do: :ok = SessionStore.delete(ctx, ctx.session)

        conn
        |> Router.put_resp_cookies(Cookies.clear_session(ctx))
        |> Plug.Conn.assign(:current_user, nil)
        |> Plug.Conn.assign(:current_session, nil)
        |> Plug.Conn.assign(:current_principal, nil)

      {:error, _invalid_host} ->
        conn
    end
  end

  defp context(conn, auth) do
    case ConnContext.new(conn, auth) do
      {:ok, ctx} -> {:ok, ctx}
      :invalid_host -> {:error, Error.new(:invalid_origin)}
    end
  end
end
