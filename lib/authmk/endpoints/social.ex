defmodule Authmk.Endpoints.Social do
  @moduledoc false
  # Social sign-in endpoints. See `Authmk.Endpoints`.

  alias Authmk.{Context, Cookies, Error, Origin, Serializer, Sessions, SessionStore, Store, URL}
  alias Authmk.OAuth.{Accounts, Discovery, Flow, State, Tokens}

  # `additional_data` rides in the state cookie, which must stay small.
  @max_additional_data 1024

  def sign_in(%Context{params: params} = ctx) do
    with {:ok, provider} <- provider(ctx, params.provider),
         :ok <-
           check_redirects(ctx, [
             params.callback_url,
             params.new_user_callback_url,
             params.error_callback_url
           ]) do
      case params.id_token do
        %{} = id_token ->
          ctx = put_additional_data(ctx, params.additional_data)
          sign_in_with_id_token(ctx, provider, id_token)

        nil ->
          data = Map.put(redirect_data(params), "request_sign_up", params.request_sign_up)
          redirect_response(ctx, provider, data)
      end
    end
  end

  def link(%Context{params: params} = ctx) do
    with {:ok, provider} <- provider(ctx, params.provider),
         :ok <- check_redirects(ctx, [params.callback_url, params.error_callback_url]) do
      data = Map.put(redirect_data(params), "link_user_id", to_string(ctx.user.id))
      redirect_response(ctx, provider, data)
    end
  end

  # OpenID Connect third-party initiated login: the provider sends the user
  # here, and an ordinary sign-in flow starts, bound to this browser.
  def initiate(%Context{params: params} = ctx) do
    with {:ok, provider} <- provider(ctx, params.provider),
         :ok <- initiation_allowed(provider, params.iss),
         :ok <- check_redirects(ctx, [params.target_link_uri]),
         {:ok, url, ctx} <-
           start_redirect(ctx, provider, %{"callback_url" => params.target_link_uri},
             login_hint: params.login_hint
           ) do
      {:redirect, url, ctx}
    else
      {:error, error} -> redirect_error(ctx, nil, error.code)
    end
  end

  # Signs out here, and returns the provider's logout URL to send the user to.
  def sign_out(%Context{params: params} = ctx) do
    with {:ok, provider} <- provider(ctx, params.provider),
         :ok <- check_redirects(ctx, [params.callback_url]),
         {:ok, url} <- end_session_url(ctx, provider, params.callback_url),
         :ok <- SessionStore.delete(ctx, ctx.session) do
      {:ok, %{url: url, redirect: true}, Cookies.clear_session(ctx)}
    end
  end

  # Apple and others post the callback cross-site, where SameSite=Lax cookies
  # aren't sent. A same-site GET to the same endpoint brings them back.
  def callback_post(%Context{raw_params: raw, endpoint: endpoint} = ctx) do
    query = Map.take(raw, ["code", "state", "error", "error_description", "user", "device_id"])
    path = String.replace(endpoint.path, ":provider", URI.encode_www_form(raw["provider"]))
    {:redirect, URL.append_query(URL.endpoint(ctx, path), Map.to_list(query)), ctx}
  end

  def callback(%Context{params: params} = ctx) do
    case State.finish(ctx, params.state) do
      {:ok, ctx, state} -> finish_callback(ctx, state)
      {:error, ctx, error} -> redirect_error(ctx, nil, error.code)
    end
  end

  def unlink(%Context{config: config, params: params, user: user} = ctx) do
    accounts = Store.all(ctx, :account, user_id: user.id)
    target = Enum.find(accounts, &account?(&1, params.provider_id, params.account_id))

    cond do
      is_nil(target) ->
        {:error, Error.new(:account_not_found)}

      length(accounts) == 1 and not config.account[:account_linking][:allow_unlinking_all] ->
        {:error, Error.new(:cannot_unlink_last_account)}

      true ->
        with {:ok, _deleted} <- Store.delete(ctx, :account, target),
             do: {:ok, %{status: true}, ctx}
    end
  end

  def access_token(%Context{params: params} = ctx) do
    with {:ok, account} <- user_account(ctx, params.provider_id, params.account_id),
         {:ok, account} <- refresh_if_expired(ctx, account) do
      {:ok, token_body(ctx, account), ctx}
    end
  end

  def refresh_token(%Context{params: params} = ctx) do
    with {:ok, account} <- user_account(ctx, params.provider_id, params.account_id),
         {:ok, account} <- refresh(ctx, account) do
      {:ok, token_body(ctx, account), ctx}
    end
  end

  def account_info(%Context{params: params} = ctx) do
    with {:ok, account} <- user_account_by_id(ctx, params.account_id),
         {:ok, provider} <- provider(ctx, account.provider_id),
         {:ok, account} <- refresh_if_expired(ctx, account),
         tokens = %Tokens{
           access_token: Accounts.read_token(ctx, account.access_token),
           id_token: Accounts.read_token(ctx, account.id_token)
         },
         {:ok, profile} <- fetch_profile(ctx, provider, tokens),
         {:ok, info} <- map_profile(ctx, provider, profile, tokens) do
      {:ok, %{user: info, data: profile}, ctx}
    end
  end

  defp redirect_data(params) do
    %{
      "callback_url" => params.callback_url,
      "error_callback_url" => params.error_callback_url,
      "new_user_callback_url" => Map.get(params, :new_user_callback_url),
      "additional_data" => params.additional_data
    }
  end

  defp redirect_response(%Context{params: params} = ctx, provider, data) do
    opts = [scopes: params.scopes, login_hint: Map.get(params, :login_hint)]

    with {:ok, url, ctx} <- start_redirect(ctx, provider, data, opts) do
      {:ok, %{url: url, redirect: not params.disable_redirect}, ctx}
    end
  end

  # The state remembers its provider: a callback to another provider's
  # endpoint fails (an IdP mix-up).
  defp start_redirect(ctx, provider, data, opts) do
    data = Map.put(data, "provider", Atom.to_string(provider.id))

    with :ok <- check_additional_data(data["additional_data"]),
         {:ok, ctx, _state, state_data} <- State.start(ctx, data) do
      {:ok, Flow.authorization_url(ctx, provider, state_data, opts), ctx}
    end
  end

  # The provider must name itself, as its issuer.
  defp initiation_allowed(provider, iss) do
    if provider.options[:idp_initiated_login] and is_binary(iss) and
         iss in List.wrap(provider.issuer),
       do: :ok,
       else: {:error, Error.new(:forbidden)}
  end

  defp end_session_url(_ctx, %{end_session_url: nil}, _callback_url),
    do: {:error, Error.new(:feature_disabled)}

  defp end_session_url(%Context{user: user} = ctx, provider, callback_url) do
    provider_id = Atom.to_string(provider.id)

    account =
      List.first(Store.all(ctx, :account, [user_id: user.id, provider_id: provider_id], limit: 1))

    {:ok,
     URL.append_query(provider.end_session_url,
       id_token_hint: account && Accounts.read_token(ctx, account.id_token),
       client_id: provider.client_id,
       post_logout_redirect_uri: callback_url && absolute(ctx, callback_url)
     )}
  end

  defp absolute(ctx, "/" <> _path = url), do: ctx.base_url <> url
  defp absolute(_ctx, url), do: url

  defp check_additional_data(nil), do: :ok

  defp check_additional_data(data) do
    if byte_size(JSON.encode!(data)) <= @max_additional_data,
      do: :ok,
      else:
        {:error,
         Error.new(:validation_failed, %{
           fields: %{additional_data: ["should be at most #{@max_additional_data} bytes"]}
         })}
  end

  # Hooks and callbacks find it in `ctx.private.oauth_additional_data`.
  defp put_additional_data(ctx, nil), do: ctx

  defp put_additional_data(ctx, data),
    do: %{ctx | private: Map.put(ctx.private, :oauth_additional_data, data)}

  defp finish_callback(%Context{params: params} = ctx, state) do
    ctx = put_additional_data(ctx, state["additional_data"])

    error_url = state["error_callback_url"]

    with :ok <- same_provider(state, params.provider),
         {:ok, provider} <- provider(ctx, params.provider),
         :ok <- no_provider_error(params),
         :ok <- code_present(params),
         {:ok, tokens} <- exchange_code(ctx, provider, state),
         {:ok, tokens} <- verify_returned_id_token(ctx, provider, tokens, state["nonce"]),
         {:ok, info} <- user_info(ctx, provider, tokens) do
      case state["link_user_id"] do
        nil -> sign_in_and_redirect(ctx, provider, info, tokens, state)
        user_id -> link_and_redirect(ctx, provider, user_id, info, tokens, state)
      end
    else
      {:error, %Error{code: :provider_error}} -> redirect_error(ctx, error_url, params.error)
      {:error, %Error{} = error} -> redirect_error(ctx, error_url, error.code)
    end
  end

  # VK sends a `device_id` with the code, and wants it back in the exchange.
  defp exchange_code(%Context{params: params} = ctx, provider, state) do
    extra = if params.device_id, do: [device_id: params.device_id], else: []
    Flow.exchange_code(ctx, provider, params.code, state["code_verifier"], extra)
  end

  # An ID token from the code exchange is checked against the provider's keys
  # when it publishes them, so the profile never rests on an unverified token.
  defp verify_returned_id_token(_ctx, %{jwks_url: nil}, tokens, _nonce), do: {:ok, tokens}

  defp verify_returned_id_token(_ctx, _provider, %Tokens{id_token: nil} = tokens, _nonce),
    do: {:ok, tokens}

  defp verify_returned_id_token(ctx, provider, tokens, nonce) do
    case provider.module.verify_id_token(ctx, provider, tokens.id_token, nonce,
           nonce_required: false
         ) do
      {:ok, claims} -> {:ok, %{tokens | claims: claims}}
      {:error, _invalid} -> {:error, Error.new(:invalid_id_token)}
    end
  end

  defp same_provider(%{"provider" => provider}, provider), do: :ok
  defp same_provider(_state, _provider), do: {:error, Error.new(:state_mismatch)}

  # The user declined, or the provider failed: its `error` param says which.
  defp no_provider_error(%{error: nil}), do: :ok
  defp no_provider_error(_params), do: {:error, Error.new(:provider_error)}

  defp code_present(%{code: code}) when is_binary(code), do: :ok
  defp code_present(_params), do: {:error, Error.new(:no_code)}

  defp sign_in_and_redirect(ctx, provider, info, tokens, state) do
    opts = [request_sign_up: state["request_sign_up"] == true]

    with {:ok, user, status} <- Accounts.sign_in(ctx, provider, info, tokens, opts),
         {:ok, ctx} <- Sessions.sign_in(ctx, user) do
      destination =
        if status == :new,
          do: state["new_user_callback_url"] || state["callback_url"],
          else: state["callback_url"]

      {:redirect, destination || "/", ctx}
    else
      {:challenge, %{redirect_url: url}, ctx} when is_binary(url) ->
        {:redirect, url, ctx}

      {:challenge, _body, ctx} ->
        redirect_error(ctx, state["error_callback_url"], :additional_verification_required)

      {:error, error} ->
        redirect_error(ctx, state["error_callback_url"], error.code)
    end
  end

  defp link_and_redirect(ctx, provider, user_id, info, tokens, state) do
    with %{} = user <- Store.get_by(ctx, :user, id: user_id),
         {:ok, _account} <- Accounts.link(ctx, provider, user, info, tokens) do
      {:redirect, state["callback_url"] || "/", ctx}
    else
      nil -> redirect_error(ctx, state["error_callback_url"], :unable_to_link_account)
      {:error, error} -> redirect_error(ctx, state["error_callback_url"], error.code)
    end
  end

  @doc false
  # For plugins that receive a provider's ID tokens their own way, like
  # Google One Tap. Signs in like `POST /sign-in/social` with an `id_token`.
  def id_token_sign_in(ctx, provider_id, token) do
    with {:ok, provider} <- provider(ctx, provider_id) do
      sign_in_with_id_token(ctx, provider, %{"token" => token})
    end
  end

  defp sign_in_with_id_token(ctx, provider, id_token) do
    with :ok <- id_token_allowed(provider),
         {:ok, claims} <- verify_id_token(ctx, provider, id_token),
         tokens = %Tokens{
           id_token: id_token["token"],
           claims: claims,
           access_token: id_token["access_token"],
           refresh_token: id_token["refresh_token"],
           # The request's other fields, like Apple's first-sign-in `user`.
           raw: id_token
         },
         {:ok, info} <- map_profile(ctx, provider, claims, tokens),
         {:ok, user, _status} <-
           Accounts.sign_in(ctx, provider, info, tokens,
             request_sign_up: Map.get(ctx.params, :request_sign_up, false)
           ),
         {:ok, ctx} <- Sessions.sign_in(ctx, user) do
      {:ok, %{redirect: false, user: Serializer.user(ctx, user)}, ctx}
    else
      {:challenge, body, ctx} -> {:ok, Map.put(body, :redirect, false), ctx}
      {:error, error} -> {:error, error}
    end
  end

  defp id_token_allowed(provider) do
    if provider.id_token_sign_in and not provider.options[:disable_id_token_sign_in],
      do: :ok,
      else: {:error, Error.new(:id_token_not_supported)}
  end

  defp verify_id_token(ctx, provider, %{"token" => token} = id_token) when is_binary(token) do
    case provider.module.verify_id_token(ctx, provider, token, id_token["nonce"], []) do
      {:ok, claims} -> {:ok, claims}
      {:error, :id_token_not_supported} -> {:error, Error.new(:id_token_not_supported)}
      {:error, _invalid} -> {:error, Error.new(:invalid_id_token)}
    end
  end

  defp verify_id_token(_ctx, _provider, _id_token), do: {:error, Error.new(:invalid_id_token)}

  defp user_info(ctx, provider, tokens) do
    with {:ok, profile} <- fetch_profile(ctx, provider, tokens) do
      map_profile(ctx, provider, profile, tokens)
    end
  end

  defp fetch_profile(ctx, provider, tokens) do
    case provider.module.user_info(tokens, provider, ctx) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:error, Error.new(:unable_to_get_user_info)}
    end
  end

  # The provider's mapping, then the app's (`c:Authmk.map_social_profile/2`).
  defp map_profile(%Context{config: config} = ctx, provider, profile, tokens) do
    with {:ok, info} <- provider.module.map_profile(profile, tokens, provider),
         :ok <- email_verified_if_required(provider, info),
         {:ok, info} <-
           config.auth.map_social_profile(
             %{provider: provider.id, user: info, profile: profile, tokens: tokens},
             ctx
           ) do
      {:ok, info}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new(:unable_to_get_user_info)}
    end
  end

  defp email_verified_if_required(provider, info) do
    if provider.options[:require_email_verification] and info[:email_verified] != true,
      do: {:error, Error.new(:email_not_verified)},
      else: :ok
  end

  # Redirect flows can't answer with JSON: the user is in the browser.
  defp redirect_error(%Context{config: config} = ctx, error_url, code) do
    url = error_url || config.errors[:error_url] || URL.endpoint(ctx, "/error")
    {:redirect, URL.append_query(url, error: code), ctx}
  end

  defp provider(%Context{config: config} = ctx, name) do
    case Enum.find(config.social_providers, fn {id, _provider} ->
           Atom.to_string(id) == to_string(name)
         end) do
      {_id, provider} -> discover(ctx, provider)
      nil -> {:error, Error.new(:oauth_provider_not_found)}
    end
  end

  defp discover(ctx, provider) do
    case Discovery.resolve(ctx, provider) do
      {:ok, provider} -> {:ok, provider}
      {:error, _reason} -> {:error, Error.new(:discovery_failed)}
    end
  end

  defp check_redirects(ctx, urls) do
    Enum.reduce_while(urls, :ok, fn url, :ok ->
      case Origin.check_redirect(ctx, url) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # The signed-in user's account for a provider (and the provider's account id, if given).
  defp user_account(%Context{user: user} = ctx, provider_id, account_id) do
    clauses =
      [user_id: user.id, provider_id: provider_id] ++
        if(account_id, do: [account_id: account_id], else: [])

    found(Store.all(ctx, :account, clauses, limit: 1))
  end

  # The signed-in user's account by its own id.
  defp user_account_by_id(%Context{user: user} = ctx, id) do
    found(Store.all(ctx, :account, [user_id: user.id, id: id], limit: 1))
  end

  defp found([account]), do: {:ok, account}
  defp found([]), do: {:error, Error.new(:account_not_found)}

  defp account?(account, provider_id, nil), do: account.provider_id == provider_id

  defp account?(account, provider_id, account_id),
    do: account.provider_id == provider_id and account.account_id == account_id

  defp refresh_if_expired(ctx, account) do
    if expired?(account.access_token_expires_at) and account.refresh_token,
      do: refresh(ctx, account),
      else: {:ok, account}
  end

  # Unknown expiry counts as valid; a few seconds of margin covers the request.
  defp expired?(nil), do: false
  defp expired?(expires_at), do: DateTime.before?(expires_at, DateTime.add(DateTime.utc_now(), 5))

  defp refresh(ctx, account) do
    with {:ok, provider} <- provider(ctx, account.provider_id),
         refresh_token when is_binary(refresh_token) <-
           Accounts.read_token(ctx, account.refresh_token),
         {:ok, tokens} <- Flow.refresh(ctx, provider, refresh_token) do
      # Providers that don't rotate refresh tokens leave it out: keep the old one.
      Accounts.update_tokens(ctx, account, %{
        tokens
        | refresh_token: tokens.refresh_token || refresh_token
      })
    else
      nil -> {:error, Error.new(:no_refresh_token)}
      error -> error
    end
  end

  defp token_body(ctx, account) do
    %{
      access_token: Accounts.read_token(ctx, account.access_token),
      access_token_expires_at: account.access_token_expires_at,
      scopes: if(account.scope, do: String.split(account.scope, ","), else: []),
      id_token: Accounts.read_token(ctx, account.id_token)
    }
  end
end
