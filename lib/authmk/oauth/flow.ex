defmodule Authmk.OAuth.Flow do
  @moduledoc """
  The OAuth 2.0 authorization code flow: the authorization URL (with PKCE),
  the code exchange, and refreshing tokens.
  """

  alias Authmk.{Context, Error, Log, URL}
  alias Authmk.OAuth.{Provider, Tokens}

  @doc "The provider's redirect URI: its option, or `<base_url>/callback/<provider>`."
  @spec redirect_uri(Context.t(), Provider.t()) :: String.t()
  def redirect_uri(ctx, %Provider{} = provider) do
    provider.options[:redirect_uri] || URL.endpoint(ctx, "/callback/#{provider.id}")
  end

  @doc """
  The URL to send the user to. `state` comes from `Authmk.OAuth.State.start/2`.
  `opts`: `:scopes` (extra), `:login_hint`.
  """
  @spec authorization_url(Context.t(), Provider.t(), map(), keyword()) :: String.t()
  def authorization_url(ctx, %Provider{} = provider, state, opts \\ []) do
    standard =
      [
        response_type: "code",
        client_id: provider.client_id,
        redirect_uri: redirect_uri(ctx, provider),
        scope: scope_param(provider, opts[:scopes]),
        state: state["state"],
        nonce: if(provider.jwks_url, do: state["nonce"]),
        login_hint: opts[:login_hint],
        prompt: provider.options[:prompt],
        response_mode: provider.options[:response_mode]
      ] ++ pkce(provider, state["code_verifier"])

    # The provider's own params replace standard ones of the same name. The
    # app's `authorize_params` come last and can't touch the flow's own.
    params =
      Keyword.merge(standard, provider.module.authorize_params(provider)) ++
        app_params(provider.options[:authorize_params])

    {base_url, fragment} = split_fragment(provider.authorize_url)
    URL.append_query(base_url, params) <> fragment
  end

  # Some providers (WeChat) need a fragment, which must come after the query.
  defp split_fragment(url) do
    case String.split(url, "#", parts: 2) do
      [base_url, fragment] -> {base_url, "#" <> fragment}
      [base_url] -> {base_url, ""}
    end
  end

  @doc """
  Exchanges an authorization code for tokens. `extra` adds form fields some
  providers send back with the code, like VK's `device_id`.
  """
  @spec exchange_code(Context.t(), Provider.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Tokens.t()} | {:error, Error.t()}
  def exchange_code(ctx, %Provider{} = provider, code, code_verifier, extra \\ []) do
    form =
      [grant_type: "authorization_code", code: code, redirect_uri: redirect_uri(ctx, provider)] ++
        if(provider.pkce, do: [code_verifier: code_verifier], else: []) ++ extra

    token_request(ctx, provider, form, :invalid_code)
  end

  @doc "Gets new tokens with a refresh token."
  @spec refresh(Context.t(), Provider.t(), String.t()) :: {:ok, Tokens.t()} | {:error, Error.t()}
  def refresh(ctx, %Provider{} = provider, refresh_token) do
    token_request(
      ctx,
      provider,
      [grant_type: "refresh_token", refresh_token: refresh_token],
      :failed_to_refresh_token
    )
  end

  defp token_request(ctx, provider, form, error_code) do
    case provider.module.token_request(ctx, provider, form) do
      {:ok, 200, %{"access_token" => _} = body} ->
        {:ok, Tokens.from_response(body, provider.options[:access_token_expires_in])}

      # Never shown to users: providers explain their errors in detail.
      response ->
        Log.warning("#{provider.name} token request failed: #{inspect(response, limit: 5)}")
        {:error, Error.new(error_code)}
    end
  end

  @reserved ~w(state client_id redirect_uri response_type code_challenge code_challenge_method nonce scope)

  defp app_params(nil), do: []
  defp app_params(params), do: params |> Map.drop(@reserved) |> Map.to_list()

  # Left out when there are no scopes.
  defp scope_param(provider, extra) do
    defaults = if provider.options[:disable_default_scopes], do: [], else: provider.scopes

    case Enum.uniq(defaults ++ (provider.options[:scopes] || []) ++ (extra || [])) do
      [] -> nil
      scopes -> Enum.join(scopes, provider.scope_separator)
    end
  end

  defp pkce(%Provider{pkce: false}, _verifier), do: []

  defp pkce(_provider, verifier) do
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
    [code_challenge: challenge, code_challenge_method: "S256"]
  end
end
