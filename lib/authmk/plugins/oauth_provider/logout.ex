defmodule Authmk.Plugins.OAuthProvider.Logout do
  @moduledoc false
  # Signing out of clients too (OpenID Connect):
  #
  # * RP-initiated logout: a client sends the user to `/oauth2/end-session`.
  #   With an ID token from the current session (`id_token_hint`) the user is
  #   signed out at once; otherwise they confirm on the app's `logout_page`,
  #   so a link alone can't sign anyone out.
  # * Back-channel logout: when sessions end, clients that got tokens
  #   through them are told, server to server, with a signed logout token.
  #   The access tokens those sessions gave out end with them.

  import Ecto.Query

  alias Authmk.{Background, Context, Cookies, Crypto, SessionStore, Store, Token, URL}
  alias Authmk.OAuth.HTTP
  alias Authmk.Plugins.JWT
  alias Authmk.Plugins.OAuthProvider.{Claims, Clients, Config}

  @purpose "oauth-logout-request"
  @max_age 600
  @event "http://schemas.openid.net/event/backchannel-logout"

  @doc "GET /oauth2/end-session"
  def end_session(%Context{raw_params: params} = ctx) do
    hint = hinted(ctx, params["id_token_hint"])
    client = Clients.fetch(ctx, params["client_id"] || hint["aud"])

    with :ok <- same_client(client, params["client_id"], hint),
         {:ok, redirect} <-
           post_logout_redirect(client, params["post_logout_redirect_uri"], params["state"]) do
      cond do
        is_nil(ctx.session) -> {:redirect, redirect, ctx}
        hint["sid"] == to_string(ctx.session.id) -> sign_out(ctx, redirect)
        true -> confirm(ctx, client, redirect)
      end
    else
      {:error, description} -> error_page(ctx, description)
    end
  end

  @doc "POST /oauth2/end-session/confirm: the user said yes on the logout page."
  def confirm_end_session(%Context{config: config, params: params} = ctx) do
    with {:ok, json} <- Crypto.verify(config, @purpose, params.logout_query),
         {:ok, %{"exp" => exp, "redirect" => redirect}} <- JSON.decode(json),
         true <- exp > System.system_time(:second) do
      {:redirect, url, ctx} = sign_out(ctx, redirect)
      {:ok, %{redirect: true, url: url}, ctx}
    else
      _invalid ->
        {:error,
         Authmk.Error.custom(:invalid_logout_query, 400, "The request expired or was changed")}
    end
  end

  # An ID token this server signed; it may have expired (OpenID Connect
  # RP-Initiated Logout 2).
  defp hinted(ctx, token) when is_binary(token) do
    case JWT.verified_claims(ctx, token) do
      {:ok, %{"iss" => iss} = claims} -> if iss == Config.issuer(ctx), do: claims, else: %{}
      :error -> %{}
    end
  end

  defp hinted(_ctx, _token), do: %{}

  defp same_client(nil, _client_id, _hint), do: :ok

  defp same_client(client, client_id, hint) do
    if client_id in [nil, client.client_id] and hint["aud"] in [nil, client.client_id],
      do: :ok,
      else: {:error, "The ID token was issued to another client"}
  end

  # Only to registered URIs; without one, this site's own page.
  defp post_logout_redirect(_client, nil, _state), do: {:ok, "/"}

  defp post_logout_redirect(nil, _uri, _state),
    do: {:error, "Name the client to be sent back to it"}

  defp post_logout_redirect(client, uri, state) do
    if uri in Clients.list(client.post_logout_redirect_uris),
      do: {:ok, URL.append_query(uri, state: state)},
      else: {:error, "post_logout_redirect_uri isn't registered for this client"}
  end

  defp confirm(%Context{config: config} = ctx, client, redirect) do
    case Config.opts(ctx)[:logout_page] do
      nil ->
        error_page(ctx, "Signing out needs an id_token_hint from this session")

      page ->
        data = %{"redirect" => redirect, "exp" => System.system_time(:second) + @max_age}
        signed = Crypto.sign(config, @purpose, JSON.encode!(data))
        page = if String.starts_with?(page, "/"), do: ctx.base_url <> page, else: page

        {:redirect,
         URL.append_query(page, client_id: client && client.client_id, logout_query: signed), ctx}
    end
  end

  defp sign_out(%Context{session: nil} = ctx, redirect), do: {:redirect, redirect, ctx}

  defp sign_out(%Context{session: session} = ctx, redirect) do
    :ok = SessionStore.delete(ctx, session)
    {:redirect, redirect, Cookies.clear_session(ctx)}
  end

  defp error_page(ctx, description),
    do:
      {:redirect,
       URL.endpoint(ctx, "/error", error: "invalid_request", error_description: description), ctx}

  @doc "Ends the sessions' access tokens and tells their clients."
  def sessions_ended(ctx, user_id, sessions) do
    session_ids = Enum.map(sessions, &to_string(&1.id))
    pairs = clients_by_session(ctx, session_ids)

    _count =
      Store.delete_all(ctx, :oauth_access_token, dynamic([a], a.session_id in ^session_ids))

    if pairs == [], do: :ok, else: notify_all(ctx, user_id, pairs)
  end

  defp notify_all(ctx, user_id, pairs) do
    case Store.get_by(ctx, :user, id: user_id) do
      nil -> :ok
      user -> Background.run(ctx, fn -> Enum.each(pairs, &notify(ctx, user, &1)) end)
    end
  end

  # {client, session id} for clients with a back-channel logout URI.
  defp clients_by_session(ctx, session_ids) do
    query =
      from(c in Store.module(ctx, :oauth_client),
        join: a in ^Store.module(ctx, :oauth_access_token),
        on: a.oauth_client_id == c.id,
        where: a.session_id in ^session_ids and not is_nil(c.backchannel_logout_uri),
        distinct: true,
        select: {c, a.session_id}
      )

    Store.list(ctx, :oauth_client, query)
  end

  defp notify(ctx, user, {client, session_id}) do
    now = System.system_time(:second)

    claims = %{
      "iss" => Config.issuer(ctx),
      "aud" => client.client_id,
      "iat" => now,
      "exp" => now + 120,
      "jti" => Token.generate(16),
      "sub" => Claims.subject(user, client, Config.opts(ctx)),
      "sid" => session_id,
      "events" => %{@event => %{}}
    }

    with {:ok, token} <- JWT.sign_claims(ctx, claims, %{"typ" => "logout+jwt"}) do
      _response = HTTP.post_form(ctx, client.backchannel_logout_uri, %{logout_token: token})
    end
  end
end
