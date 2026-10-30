defmodule Authmk.Plugins.SSO.SignIn do
  @moduledoc false
  # Sign-in with an organization's identity provider (OpenID Connect): the
  # authorization code flow with PKCE and a nonce, bound to this browser by
  # the state cookie, like social sign-in.

  alias Authmk.{Context, Email, Error, Origin}
  alias Authmk.OAuth.{Discovery, Flow, State}
  alias Authmk.Plugins.SSO.{Outcome, Providers, SAMLSignIn, Users}

  @doc "POST /sign-in/sso: the provider's URL to send the user to."
  def start(%Context{params: params} = ctx) do
    with {:ok, provider} <- pick(ctx, params),
         :ok <- check_redirects(ctx, params) do
      case provider do
        %{type: "saml"} -> SAMLSignIn.start(ctx, provider)
        _oidc -> start_oidc(ctx, provider)
      end
    end
  end

  defp start_oidc(%Context{params: params} = ctx, provider) do
    with {:ok, oauth} <- discovered(Providers.http_context(ctx, provider), provider) do
      data = %{
        "sso_provider_id" => provider.provider_id,
        "callback_url" => params.callback_url,
        "new_user_callback_url" => params.new_user_callback_url,
        "error_callback_url" => params.error_callback_url
      }

      with {:ok, ctx, _state, data} <- State.start(ctx, data) do
        url = Flow.authorization_url(ctx, oauth, data, login_hint: params.email)
        {:ok, %{url: url, redirect: true}, ctx}
      end
    end
  end

  # Named outright, or by organization, or by the email's domain.
  defp pick(ctx, params) do
    provider =
      cond do
        params.provider_id -> Providers.find(ctx, params.provider_id)
        params.organization_id -> Providers.for_organization(ctx, params.organization_id)
        domain = params.domain || email_domain(params.email) -> Providers.for_domain(ctx, domain)
        true -> nil
      end

    if provider,
      do: {:ok, provider},
      else: {:error, Error.custom(:sso_provider_not_found, 404, "No single sign-on for this")}
  end

  defp email_domain(nil), do: nil

  defp email_domain(email) do
    case String.split(Email.normalize(email), "@") do
      [_local, domain] -> domain
      _invalid -> nil
    end
  end

  defp check_redirects(ctx, params) do
    [params.callback_url, params.new_user_callback_url, params.error_callback_url]
    |> Enum.reduce_while(:ok, fn url, :ok ->
      case Origin.check_redirect(ctx, url) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp discovered(ctx, provider) do
    case Discovery.resolve(ctx, Providers.oauth_provider(ctx, provider)) do
      {:ok, oauth} ->
        {:ok, oauth}

      _failed ->
        {:error,
         Error.custom(:sso_provider_unavailable, 502, "The identity provider can't be reached")}
    end
  end

  @doc "GET /sso/callback and /sso/callback/:provider_id"
  def callback(%Context{raw_params: params} = ctx) do
    case State.finish(ctx, params["state"]) do
      {:ok, ctx, state} -> finish(ctx, state, params)
      {:error, ctx, error} -> Outcome.redirect_error(ctx, nil, error.code)
    end
  end

  defp finish(ctx, state, params) do
    error_url = state["error_callback_url"]

    with :ok <- same_provider(state, params["provider_id"]),
         %{} = provider <-
           Providers.find(ctx, state["sso_provider_id"]) || {:error, Error.new(:state_mismatch)},
         :ok <- no_provider_error(params),
         remote = Providers.http_context(ctx, provider),
         {:ok, oauth} <- discovered(remote, provider),
         {:ok, tokens} <-
           Flow.exchange_code(remote, oauth, params["code"] || "", state["code_verifier"]),
         {:ok, tokens} <- verify_id_token(remote, oauth, tokens, state["nonce"]),
         {:ok, profile} <- profile(remote, oauth, tokens),
         {:ok, info} <- oauth.module.map_profile(profile, tokens, oauth),
         {:ok, user, status} <- Users.resolve(ctx, provider, info, profile) do
      Outcome.complete(ctx, user, status, state)
    else
      {:error, %Error{} = error} -> Outcome.redirect_error(ctx, error_url, error.code)
      {:error, _reason} -> Outcome.redirect_error(ctx, error_url, :invalid_sso_response)
    end
  end

  # The callback path names the provider, unless it's the shared one.
  defp same_provider(_state, nil), do: :ok
  defp same_provider(%{"sso_provider_id" => id}, id), do: :ok
  defp same_provider(_state, _other), do: {:error, Error.new(:state_mismatch)}

  defp no_provider_error(%{"error" => error}) when is_binary(error),
    do: {:error, Error.custom(:provider_error, 400, "The identity provider refused")}

  defp no_provider_error(_params), do: :ok

  # OpenID Connect only: the ID token must be there, signed, for us, with
  # our nonce.
  defp verify_id_token(_ctx, _oauth, %{id_token: nil}, _nonce),
    do: {:error, Error.new(:invalid_id_token)}

  defp verify_id_token(ctx, oauth, tokens, nonce) do
    case oauth.module.verify_id_token(ctx, oauth, tokens.id_token, nonce, nonce_required: true) do
      {:ok, claims} -> {:ok, %{tokens | claims: claims}}
      {:error, _invalid} -> {:error, Error.new(:invalid_id_token)}
    end
  end

  defp profile(ctx, oauth, tokens) do
    case oauth.module.user_info(tokens, oauth, ctx) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:error, Error.new(:unable_to_get_user_info)}
    end
  end
end
