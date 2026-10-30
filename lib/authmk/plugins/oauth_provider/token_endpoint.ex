defmodule Authmk.Plugins.OAuthProvider.TokenEndpoint do
  @moduledoc false
  # POST /oauth2/token: the authorization code, refresh token and client
  # credentials grants.

  alias Authmk.{Context, SessionStore, Store}
  alias Authmk.Plugins.DeviceAuthorization

  alias Authmk.Plugins.OAuthProvider.{
    Assertions,
    Authorize,
    Clients,
    Config,
    DPoP,
    Errors,
    Requests,
    Tokens
  }

  @device_code "urn:ietf:params:oauth:grant-type:device_code"
  @jwt_bearer "urn:ietf:params:oauth:grant-type:jwt-bearer"

  def token(%Context{raw_params: params} = ctx) do
    with {:ok, client} <- authenticate(ctx),
         {:ok, jkt} <- dpop(ctx, client) do
      grant(Context.put_private(ctx, :dpop_jkt, jkt), client, params["grant_type"], params)
    end
  end

  defp authenticate(ctx) do
    case Clients.authenticate(ctx) do
      {:ok, client} -> {:ok, client}
      :error -> Errors.invalid_client(ctx)
    end
  end

  # A proof binds the tokens to the client's key; some clients must send one.
  defp dpop(%Context{conn: conn} = ctx, client) do
    case DPoP.verify(ctx, conn, "POST", Authmk.URL.endpoint(ctx, "/oauth2/token")) do
      {:ok, jkt} ->
        {:ok, jkt}

      :none ->
        if client.dpop_bound_access_tokens,
          do: Errors.json(ctx, "invalid_dpop_proof", "A DPoP proof is required"),
          else: {:ok, nil}

      :error ->
        Errors.json(ctx, "invalid_dpop_proof", "The DPoP proof is invalid")
    end
  end

  defp grant(ctx, client, grant_type, params) do
    cond do
      not is_binary(grant_type) ->
        Errors.json(ctx, "invalid_request", "grant_type is required")

      grant_type not in supported_grants(ctx) ->
        Errors.json(ctx, "unsupported_grant_type")

      grant_type not in Clients.list(client.grant_types) ->
        Errors.json(ctx, "unauthorized_client", "The client can't use this grant")

      true ->
        run(ctx, client, grant_type, params)
    end
  end

  defp run(ctx, client, "authorization_code", params), do: authorization_code(ctx, client, params)
  defp run(ctx, client, "refresh_token", params), do: refresh_token(ctx, client, params)
  defp run(ctx, client, "client_credentials", params), do: client_credentials(ctx, client, params)
  defp run(ctx, client, @device_code, params), do: device_code(ctx, client, params)
  defp run(ctx, client, @jwt_bearer, params), do: jwt_bearer(ctx, client, params)

  @doc "The grants this server takes, with the plugins and options it has."
  def supported_grants(%Context{config: config} = ctx) do
    plugins = Enum.map(config.plugins, &elem(&1, 0))

    ["authorization_code", "refresh_token", "client_credentials"] ++
      if(DeviceAuthorization in plugins, do: [@device_code], else: []) ++
      if(Config.opts(ctx)[:jwt_bearer_subject], do: [@jwt_bearer], else: [])
  end

  # RFC 8628, with codes from Authmk.Plugins.DeviceAuthorization.
  defp device_code(ctx, client, params) do
    resource = params["resource"]

    if Requests.resource_allowed?(resource, opts(ctx)),
      do:
        DeviceAuthorization.redeem(
          ctx,
          params["device_code"],
          client.client_id,
          &issue_for_device(&1, client, &2, &3, resource)
        ),
      else: Errors.json(ctx, "invalid_target", "Unknown resource")
  end

  defp issue_for_device(ctx, client, user, scope, resource) do
    scopes = String.split(scope || "", " ", trim: true)
    grant = %{user: user, scopes: scopes, auth_time: DateTime.utc_now(), resource: resource}

    if Enum.all?(scopes, &(&1 in allowed_scopes(ctx, client))),
      do: respond(ctx, client, grant),
      else: Errors.json(ctx, "invalid_scope", "The client can't ask for these scopes")
  end

  # RFC 7523 2.1: the client signs an assertion naming the user it acts for.
  defp jwt_bearer(ctx, client, params) do
    audiences = [Config.issuer(ctx), Authmk.URL.endpoint(ctx, "/oauth2/token")]
    scopes = String.split(params["scope"] || "", " ", trim: true)

    allowed = allowed_scopes(ctx, client) -- ["offline_access"]

    with {:ok, claims} <- Assertions.verify(ctx, client, params["assertion"], audiences),
         %{} = user <- Config.opts(ctx)[:jwt_bearer_subject].(claims["sub"], client, ctx) do
      if Enum.all?(scopes, &(&1 in allowed)),
        do: respond(ctx, client, %{user: user, scopes: scopes, auth_time: DateTime.utc_now()}),
        else: Errors.json(ctx, "invalid_scope", "The client can't ask for these scopes")
    else
      _invalid -> Errors.json(ctx, "invalid_grant", "The assertion isn't valid")
    end
  end

  defp allowed_scopes(ctx, client) do
    case Clients.list(client.scopes) do
      [] -> Config.opts(ctx)[:scopes]
      scopes -> scopes
    end
  end

  defp authorization_code(ctx, client, params) do
    with {:code, {:ok, data}} <- {:code, Authorize.consume_code(ctx, params["code"])},
         :ok <- same(data["client_id"], client.client_id),
         :ok <- same(data["redirect_uri"], params["redirect_uri"]),
         :ok <- pkce(data["code_challenge"], params["code_verifier"]),
         {:ok, resource} <- same_resource(data["resource"], params["resource"]),
         %{} = user <- Store.get_by(ctx, :user, id: data["user_id"]),
         :ok <- session_alive(ctx, user, data["session_id"]) do
      grant = %{
        user: user,
        scopes: data["scopes"],
        session_id: data["session_id"],
        nonce: data["nonce"],
        auth_time: DateTime.from_unix!(data["auth_time"]),
        resource: resource
      }

      respond(ctx, client, grant)
    else
      {:code, :error} ->
        Errors.json(ctx, "invalid_grant", "The code is invalid, used or expired")

      :invalid_target ->
        Errors.json(ctx, "invalid_target", "The code wasn't issued for this resource")

      _mismatch ->
        Errors.json(ctx, "invalid_grant", "The code wasn't issued for this request")
    end
  end

  defp same(expected, actual) when is_binary(expected) and is_binary(actual),
    do: if(Plug.Crypto.secure_compare(expected, actual), do: :ok, else: :error)

  defp same(_expected, _actual), do: :error

  # The token is for the resource the user approved, if any.
  defp same_resource(authorized, nil), do: {:ok, authorized}
  defp same_resource(authorized, authorized), do: {:ok, authorized}
  defp same_resource(_authorized, _other), do: :invalid_target

  # A code issued with a challenge needs its verifier, and one issued
  # without can't be redeemed with one (RFC 9700 2.1.1).
  defp pkce(nil, nil), do: :ok
  defp pkce(nil, _verifier), do: :error

  defp pkce(challenge, verifier) when is_binary(verifier) do
    if Regex.match?(~r/\A[A-Za-z0-9\-._~]{43,128}\z/, verifier) do
      computed = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
      same(challenge, computed)
    else
      :error
    end
  end

  defp pkce(_challenge, _verifier), do: :error

  # A code is only as good as the sign-in it came from.
  defp session_alive(ctx, user, session_id) do
    now = DateTime.utc_now()

    alive =
      Enum.any?(SessionStore.list(ctx, user.id), fn session ->
        to_string(session.id) == session_id and DateTime.after?(session.expires_at, now)
      end)

    if alive, do: :ok, else: :error
  end

  # Refresh tokens rotate: each use gives a new one. A token used again
  # within `refresh_token_reuse_interval` (a retry after a lost answer)
  # still works once more; after that, reuse means a leak, and the whole
  # chain ends.
  defp refresh_token(ctx, client, params) do
    opts = opts(ctx)
    refresh = Tokens.find_refresh(ctx, params["refresh_token"])
    now = DateTime.utc_now()

    cond do
      is_nil(refresh) or refresh.oauth_client_id != client.id ->
        Errors.json(ctx, "invalid_grant", "Unknown refresh token")

      DateTime.before?(refresh.expires_at, now) ->
        Errors.json(ctx, "invalid_grant", "The refresh token expired")

      refresh.dpop_jkt && refresh.dpop_jkt != ctx.private[:dpop_jkt] ->
        Errors.json(ctx, "invalid_dpop_proof", "The refresh token is bound to another key")

      refresh.revoked_at &&
          DateTime.diff(now, refresh.revoked_at) > opts[:refresh_token_reuse_interval] ->
        :ok = Tokens.revoke_family(ctx, refresh.family_id)
        Errors.json(ctx, "invalid_grant", "The refresh token was already used")

      true ->
        rotate(ctx, client, refresh, params)
    end
  end

  defp rotate(ctx, client, refresh, params) do
    granted = Clients.list(refresh.scopes)

    with {:ok, scopes} <- narrowed_scopes(params["scope"], granted),
         {:ok, resource} <- same_resource(refresh.resource, params["resource"]),
         %{} = user <- Store.get_by(ctx, :user, id: refresh.user_id),
         :ok <- revoke_unless_retry(ctx, refresh) do
      grant = %{
        user: user,
        scopes: scopes,
        session_id: refresh.session_id,
        auth_time: refresh.auth_time,
        family_id: refresh.family_id,
        refresh_scopes: granted,
        resource: resource
      }

      respond(ctx, client, grant)
    else
      :invalid_scope ->
        Errors.json(ctx, "invalid_scope", "Only granted scopes can be asked for")

      :invalid_target ->
        Errors.json(ctx, "invalid_target", "The token wasn't issued for this resource")

      nil ->
        Errors.json(ctx, "invalid_grant", "The user is gone")
    end
  end

  defp revoke_unless_retry(_ctx, %{revoked_at: %DateTime{}}), do: :ok
  defp revoke_unless_retry(ctx, refresh), do: Tokens.revoke_refresh(ctx, refresh)

  defp narrowed_scopes(nil, granted), do: {:ok, granted}

  defp narrowed_scopes(scope, granted) when is_binary(scope) do
    scopes = String.split(scope, " ", trim: true)

    if scopes != [] and Enum.all?(scopes, &(&1 in granted)),
      do: {:ok, scopes},
      else: :invalid_scope
  end

  defp narrowed_scopes(_scope, _granted), do: :invalid_scope

  # For the client itself: no user, so no refresh or ID token.
  defp client_credentials(ctx, client, params) do
    allowed = Clients.list(client.scopes) -- ["openid", "offline_access"]

    requested =
      case params["scope"] do
        scope when is_binary(scope) -> String.split(scope, " ", trim: true)
        _none -> allowed
      end

    cond do
      not Enum.all?(requested, &(&1 in allowed)) ->
        Errors.json(ctx, "invalid_scope", "The client can't ask for these scopes")

      not Requests.resource_allowed?(params["resource"], opts(ctx)) ->
        Errors.json(ctx, "invalid_target", "Unknown resource")

      true ->
        respond(ctx, client, %{scopes: requested, resource: params["resource"]})
    end
  end

  defp respond(ctx, client, grant) do
    grant = Map.put(grant, :dpop_jkt, ctx.private[:dpop_jkt])

    case Tokens.issue(ctx, client, grant, opts(ctx)) do
      {:ok, body} -> {:json, 200, body, Errors.no_store(ctx)}
      {:error, _error} -> Errors.json(ctx, "server_error", nil, 500)
    end
  end

  defp opts(ctx), do: Config.opts(ctx)
end
