defmodule Authmk.Plugins.OAuthProvider.Authorize do
  @moduledoc false
  # The authorization endpoint and the two pages it may stop at: sign-in
  # (then `/oauth2/continue`) and consent (then `/oauth2/consent`).
  #
  # Until the client's redirect URI is known to be registered, errors go to
  # authmk's error page, never to the URI (RFC 6749 4.1.2.1).

  alias Authmk.{Context, Crypto, Store, URL, Verification}
  alias Authmk.Plugins.OAuthProvider.{Clients, Config, PushedRequests, Requests}

  @request_purpose "oauth-authorize-request"
  @request_max_age 600
  @code_purpose "oauth-code"

  @doc "GET /oauth2/authorize, with the params or a pushed request's `request_uri`."
  def authorize(%Context{raw_params: params} = ctx) do
    with {:ok, params} <- request_params(ctx, params),
         {:ok, request} <- parse(ctx, params) do
      proceed(ctx, request)
    end
  end

  defp request_params(ctx, %{"request_uri" => request_uri} = params) do
    case PushedRequests.take(ctx, request_uri, params["client_id"]) do
      {:ok, pushed} -> {:ok, pushed}
      :error -> error_page(ctx, "invalid_request_uri", "The pushed request expired or was used")
    end
  end

  defp request_params(ctx, params) do
    if Config.opts(ctx)[:require_pushed_authorization_requests],
      do: error_page(ctx, "invalid_request", "Push the request to /oauth2/par first"),
      else: {:ok, params}
  end

  @doc "POST /oauth2/continue: after the sign-in page, with `oauth_query`."
  def continue(%Context{} = ctx) do
    with {:ok, request} <- signed_request(ctx) do
      proceed(ctx, request)
    end
    |> answer()
  end

  @doc """
  POST /oauth2/consent: the user's answer. `accept: false` sends the client
  `access_denied`. `scope` may narrow what was asked.
  """
  def consent(%Context{params: params, user: user} = ctx) do
    with {:ok, request} <- signed_request(ctx),
         {:ok, scopes} <- granted_scopes(request, params.scope) do
      if params.accept do
        :ok = save_consent(ctx, request.client, user, scopes)
        issue_code(ctx, %{request | scopes: scopes})
      else
        {:redirect, error_url(request, "access_denied", "The user said no"), ctx}
      end
    end
    |> answer()
  end

  # The pages call these with fetch: redirects become JSON to follow.
  defp answer({:redirect, url, ctx}), do: {:ok, %{redirect: true, url: url}, ctx}
  defp answer(other), do: other

  # Checks every param; afterwards the client and redirect URI are trusted.
  defp parse(ctx, params) do
    opts = opts(ctx)

    with {:ok, client} <- client(ctx, params["client_id"]),
         {:ok, redirect_uri} <- redirect_uri(ctx, client, params["redirect_uri"], opts) do
      request = %{
        client: client,
        client_id: client.client_id,
        redirect_uri: redirect_uri,
        state: params["state"],
        issuer: Config.issuer(ctx),
        scopes: [],
        nonce: params["nonce"],
        prompt: String.split(params["prompt"] || "", " ", trim: true),
        max_age: Requests.max_age(params["max_age"]),
        signed_in_after: params["signed_in_after"],
        code_challenge: params["code_challenge"],
        code_challenge_method: params["code_challenge_method"],
        resource: params["resource"]
      }

      case Requests.check(ctx, client, params, opts) do
        {:ok, scopes} -> {:ok, %{request | scopes: scopes}}
        {:error, code, description} -> {:redirect, error_url(request, code, description), ctx}
      end
    end
  end

  # These errors can't be sent to the client: its redirect URI isn't
  # trusted yet.
  defp client(ctx, client_id) do
    case Clients.fetch(ctx, client_id) do
      nil -> error_page(ctx, "invalid_client", "Unknown client")
      client -> {:ok, client}
    end
  end

  defp redirect_uri(ctx, client, nil, _opts) do
    case Clients.list(client.redirect_uris) do
      [only] -> {:ok, only}
      _several -> error_page(ctx, "invalid_request", "redirect_uri is required")
    end
  end

  defp redirect_uri(ctx, client, uri, opts) do
    if Clients.redirect_uri_allowed?(client, uri, opts),
      do: {:ok, uri},
      else: error_page(ctx, "invalid_request", "redirect_uri isn't registered for this client")
  end

  # Signed in, recently enough, and consented: the code. Otherwise the
  # sign-in or consent page, or an error when the client said prompt=none.
  defp proceed(%Context{} = ctx, request) do
    opts = opts(ctx)

    cond do
      needs_sign_in?(ctx, request) and "none" in request.prompt ->
        {:redirect, error_url(request, "login_required", "The user isn't signed in"), ctx}

      needs_sign_in?(ctx, request) ->
        {:redirect, page(ctx, opts[:login_page], request), ctx}

      not reference_allowed?(ctx, request.client) ->
        {:redirect,
         error_url(request, "access_denied", "This app is for its organization's members"), ctx}

      needs_consent?(ctx, request) and "none" in request.prompt ->
        {:redirect, error_url(request, "consent_required", "The user hasn't consented"), ctx}

      needs_consent?(ctx, request) ->
        {:redirect, page(ctx, opts[:consent_page], request), ctx}

      true ->
        issue_code(ctx, request)
    end
  end

  # `prompt=login` and `max_age` ask for a recent sign-in. The request sent
  # to the sign-in page drops `prompt=login` but remembers when it was
  # made, so only a sign-in after that counts.
  defp needs_sign_in?(%Context{session: nil}, _request), do: true

  defp needs_sign_in?(%Context{session: session}, request) do
    auth_time = DateTime.to_unix(session.inserted_at)

    "login" in request.prompt or
      (is_integer(request.signed_in_after) and auth_time < request.signed_in_after) or
      (is_integer(request.max_age) and System.system_time(:second) - auth_time > request.max_age)
  end

  # Clients owned by an organization (or other reference) may be limited to
  # its members.
  defp reference_allowed?(%Context{user: user} = ctx, %{reference_id: reference_id})
       when is_binary(reference_id) do
    case opts(ctx)[:reference_access] do
      nil -> true
      allowed? -> allowed?.(user, reference_id, ctx) == true
    end
  end

  defp reference_allowed?(_ctx, _client), do: true

  defp needs_consent?(%Context{user: user} = ctx, request) do
    cond do
      "consent" in request.prompt -> true
      Clients.trusted?(ctx, request.client) -> false
      true -> not consented?(ctx, request.client, user, request.scopes)
    end
  end

  defp consented?(ctx, client, user, scopes) do
    case Store.get_by(ctx, :oauth_consent, oauth_client_id: client.id, user_id: user.id) do
      nil -> false
      consent -> Enum.all?(scopes, &(&1 in Clients.list(consent.scopes)))
    end
  end

  defp save_consent(ctx, client, user, scopes) do
    result =
      case Store.get_by(ctx, :oauth_consent, oauth_client_id: client.id, user_id: user.id) do
        nil ->
          Store.insert(ctx, :oauth_consent, %{
            oauth_client_id: client.id,
            user_id: user.id,
            scopes: Enum.join(scopes, " "),
            reference_id: client.reference_id
          })

        consent ->
          all = Enum.uniq(Clients.list(consent.scopes) ++ scopes)
          Store.update(ctx, :oauth_consent, consent, %{scopes: Enum.join(all, " ")})
      end

    with {:ok, _consent} <- result, do: :ok
  end

  defp issue_code(%Context{user: user, session: session} = ctx, request) do
    data = %{
      "client_id" => request.client_id,
      "redirect_uri" => request.redirect_uri,
      "scopes" => request.scopes,
      "user_id" => to_string(user.id),
      "session_id" => to_string(session.id),
      "auth_time" => DateTime.to_unix(session.inserted_at),
      "nonce" => request.nonce,
      "code_challenge" => request.code_challenge,
      "resource" => request.resource
    }

    {:ok, code} = Verification.create(ctx, @code_purpose, data, opts(ctx)[:code_expires_in])

    url =
      URL.append_query(request.redirect_uri,
        code: code,
        state: request.state,
        iss: request.issuer
      )

    {:redirect, url, ctx}
  end

  @doc "Takes an authorization code: its data, once, or `:error`."
  def consume_code(ctx, code) do
    case Verification.consume(ctx, @code_purpose, code) do
      {:ok, data} -> {:ok, data}
      _invalid -> :error
    end
  end

  # The sign-in or consent page, with the request signed so it comes back
  # unchanged.
  defp page(%Context{config: config} = ctx, page, request) do
    params = %{
      "client_id" => request.client_id,
      "redirect_uri" => request.redirect_uri,
      "scope" => Enum.join(request.scopes, " "),
      "state" => request.state,
      "nonce" => request.nonce,
      "prompt" => Enum.join(request.prompt -- ["login"], " "),
      "max_age" => request.max_age,
      "code_challenge" => request.code_challenge,
      "code_challenge_method" => request.code_challenge_method,
      "signed_in_after" => signed_in_after(request),
      "resource" => request.resource,
      "response_type" => "code",
      "exp" => System.system_time(:second) + @request_max_age
    }

    signed = Crypto.sign(config, @request_purpose, JSON.encode!(params))
    url = if String.starts_with?(page, "/"), do: ctx.base_url <> page, else: page

    URL.append_query(url,
      client_id: request.client_id,
      scope: params["scope"],
      oauth_query: signed
    )
  end

  defp signed_in_after(request) do
    if "login" in request.prompt,
      do: System.system_time(:second),
      else: request.signed_in_after
  end

  defp signed_request(%Context{config: config, params: params} = ctx) do
    with {:ok, json} <- Crypto.verify(config, @request_purpose, params.oauth_query),
         {:ok, %{"exp" => exp} = request_params} when is_integer(exp) <- JSON.decode(json),
         true <- exp > System.system_time(:second) do
      parse(ctx, request_params)
    else
      _invalid ->
        {:error,
         Authmk.Error.custom(:invalid_oauth_query, 400, "The request expired or was changed")}
    end
  end

  defp granted_scopes(request, nil), do: {:ok, request.scopes}

  defp granted_scopes(request, scope) do
    scopes = String.split(scope, " ", trim: true)

    if scopes != [] and Enum.all?(scopes, &(&1 in request.scopes)),
      do: {:ok, scopes},
      else:
        {:error, Authmk.Error.custom(:invalid_scope, 400, "Only scopes asked for can be granted")}
  end

  defp error_url(request, code, description) do
    URL.append_query(request.redirect_uri,
      error: code,
      error_description: description,
      state: request.state,
      iss: request.issuer
    )
  end

  defp error_page(ctx, code, description) do
    {:redirect, URL.endpoint(ctx, "/error", error: code, error_description: description), ctx}
  end

  defp opts(ctx), do: Config.opts(ctx)
end
