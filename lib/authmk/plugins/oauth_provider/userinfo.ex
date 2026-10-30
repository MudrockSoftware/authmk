defmodule Authmk.Plugins.OAuthProvider.Userinfo do
  @moduledoc false
  # GET/POST /oauth2/userinfo: the user's claims, for an access token with
  # the openid scope.

  alias Authmk.{Context, Store, URL}
  alias Authmk.Plugins.OAuthProvider.{Claims, Clients, Config, DPoP, Tokens}

  def userinfo(%Context{} = ctx) do
    with {:ok, scheme, token} <- access_token(ctx),
         {access, client} <- Tokens.find_access(ctx, token),
         :ok <- check_binding(ctx, scheme, token, access),
         true <- "openid" in Clients.list(access.scopes),
         %{} = user <- access.user_id && Store.get_by(ctx, :user, id: access.user_id) do
      opts = Config.opts(ctx)
      claims = Claims.user_claims(user, client, Clients.list(access.scopes), opts)
      {:json, 200, claims, Context.put_resp_header(ctx, "cache-control", "no-store")}
    else
      :missing -> unauthorized(ctx, ~s(Bearer realm="oauth"))
      _invalid -> unauthorized(ctx, ~s(Bearer realm="oauth", error="invalid_token"))
    end
  end

  # RFC 6750: in the header, or in a form body. RFC 9449: `DPoP <token>`.
  defp access_token(%Context{conn: conn, raw_params: params}) do
    case {Plug.Conn.get_req_header(conn, "authorization"), params["access_token"]} do
      {["Bearer " <> token], nil} -> {:ok, :bearer, String.trim(token)}
      {["DPoP " <> token], nil} -> {:ok, :dpop, String.trim(token)}
      {[], token} when is_binary(token) -> {:ok, :bearer, token}
      _missing_or_both -> :missing
    end
  end

  # A DPoP-bound token needs its key's proof; a plain one, no proof.
  defp check_binding(_ctx, :bearer, _token, %{dpop_jkt: nil}), do: :ok

  defp check_binding(%Context{conn: conn} = ctx, :dpop, token, %{dpop_jkt: jkt})
       when is_binary(jkt) do
    case DPoP.verify(ctx, conn, conn.method, URL.endpoint(ctx, "/oauth2/userinfo"), token) do
      {:ok, ^jkt} -> :ok
      _invalid -> :error
    end
  end

  defp check_binding(_ctx, _scheme, _token, _access), do: :error

  defp unauthorized(ctx, challenge) do
    ctx = Context.put_resp_header(ctx, "www-authenticate", challenge)
    {:json, 401, %{error: "invalid_token"}, ctx}
  end
end
