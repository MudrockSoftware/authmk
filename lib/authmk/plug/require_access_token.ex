defmodule Authmk.Plug.RequireAccessToken do
  @moduledoc """
  Protects API routes with access tokens from `Authmk.Plugins.OAuthProvider`.

      plug Authmk.Plug.RequireAccessToken, auth: MyApp.Auth, scopes: ["read"]

  Options:

    * `:auth` - your auth module (required)
    * `:scopes` - scopes the token must have
    * `:resource` - the resource (audience) the token must be for
    * `:resource_metadata` - your protected resource metadata URL
      (RFC 9728), sent to clients that need a token, as MCP clients expect

  DPoP-bound tokens (RFC 9449) come as `Authorization: DPoP <token>` with
  a proof for this request's method and URL; pass `:url` when the app sits
  behind a proxy that changes the scheme or host (`fn conn -> url end`).

  With a valid token, the conn gets `:access_token` (what
  `Authmk.Plugins.OAuthProvider.verify_access_token/3` returns) and
  `:current_user` (or `nil` for client credentials tokens). Otherwise it
  halts with 401 (no or bad token) or 403 (missing scope), and a
  `WWW-Authenticate` header saying why (RFC 6750).
  """

  @behaviour Plug

  import Plug.Conn

  alias Authmk.Context
  alias Authmk.Plugins.OAuthProvider
  alias Authmk.Plugins.OAuthProvider.DPoP

  @impl true
  def init(opts) do
    _auth = Keyword.fetch!(opts, :auth)
    opts
  end

  @impl true
  def call(conn, opts) do
    auth = opts[:auth]

    with {:ok, scheme, token} <- access_token(conn),
         {:ok, jkt} <- dpop(conn, auth, scheme, token, opts),
         verify_opts = [dpop_jkt: jkt] ++ Keyword.take(opts, [:scopes, :resource]),
         {:ok, access} <- OAuthProvider.verify_access_token(auth, token, verify_opts) do
      conn
      |> assign(:access_token, access)
      |> assign(:current_user, user(auth, access.user_id))
    else
      :missing -> refuse(conn, 401, nil, opts)
      :invalid_proof -> refuse(conn, 401, "invalid_token", opts)
      {:error, %{code: :insufficient_scope}} -> refuse(conn, 403, "insufficient_scope", opts)
      {:error, _invalid} -> refuse(conn, 401, "invalid_token", opts)
    end
  end

  defp access_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, :bearer, String.trim(token)}
      ["DPoP " <> token] -> {:ok, :dpop, String.trim(token)}
      _none -> :missing
    end
  end

  defp dpop(_conn, _auth, :bearer, _token, _opts), do: {:ok, nil}

  defp dpop(conn, auth, :dpop, token, opts) do
    url = if opts[:url], do: opts[:url].(conn), else: request_url(conn)

    case DPoP.verify(Context.new(auth.config()), conn, conn.method, url, token) do
      {:ok, jkt} -> {:ok, jkt}
      _none_or_invalid -> :invalid_proof
    end
  end

  defp user(_auth, nil), do: nil

  defp user(auth, user_id),
    do: Authmk.Store.get_by(Context.new(auth.config()), :user, id: user_id)

  defp refuse(conn, status, error, opts) do
    challenge =
      [
        ~s(realm="api"),
        error && ~s(error="#{error}"),
        status == 403 && opts[:scopes] && ~s(scope="#{Enum.join(opts[:scopes], " ")}"),
        opts[:resource_metadata] && ~s(resource_metadata="#{opts[:resource_metadata]}")
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(", ")

    body = JSON.encode!(%{error: error || "invalid_request"})

    conn
    |> put_resp_header("www-authenticate", "Bearer " <> challenge)
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
