defmodule Authmk.Plugins.SSO.SAMLSignIn do
  @moduledoc false
  # Sign-in with a SAML 2.0 identity provider, in three steps:
  #
  #   1. start: the state cookie is set (as for OpenID Connect) and the user
  #      sent to the provider with an AuthnRequest, RelayState = state.
  #   2. acs: the provider's page posts the Response here, cross-site, so
  #      without our SameSite cookies. It's checked, its assertion recorded
  #      against replay, and the identity kept under a one-time code.
  #   3. finish: the browser follows us here with its cookies, so the
  #      Response is matched to the request this browser started
  #      (InResponseTo) before anyone is signed in.
  #
  # IdP-initiated sign-in (no request) is refused unless the provider has
  # `allow_idp_initiated: true`.

  require Logger

  alias Authmk.{Context, Error, Origin, SessionStore, URL, Verification}
  alias Authmk.OAuth.State
  alias Authmk.Plugins.SSO.{Config, Outcome, Providers, SAMLConfig, Users}
  alias Authmk.Plugins.SSO.SAML.{Metadata, Profile, Replay, Request, Response}

  @code_purpose "sso-saml-sign-in"
  @code_ttl 120
  @name_id_format "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"

  @doc "From POST /sign-in/sso: the provider's URL, with the request."
  def start(%Context{params: params} = ctx, provider) do
    request_id = Request.new_id()

    data = %{
      "sso_provider_id" => provider.provider_id,
      "saml_request_id" => request_id,
      "callback_url" => params.callback_url,
      "new_user_callback_url" => params.new_user_callback_url,
      "error_callback_url" => params.error_callback_url
    }

    with {:ok, ctx, state, _data} <- State.start(ctx, data) do
      url =
        Request.redirect_url(%{
          id: request_id,
          sso_url: provider.saml.sso_url,
          issuer: SAMLConfig.entity_id(ctx, provider),
          acs_url: SAMLConfig.acs_url(ctx, provider),
          relay_state: state,
          signing_key: signing_key(ctx),
          name_id_format: @name_id_format
        })

      {:ok, %{url: url, redirect: true}, ctx}
    end
  end

  @doc "POST /sso/saml2/acs/:provider_id"
  def acs(%Context{raw_params: params} = ctx) do
    with %{type: "saml"} = provider <- Providers.find(ctx, params["provider_id"]),
         {:ok, identity} <-
           Response.validate(params["SAMLResponse"] || "", expected(ctx, provider)),
         :ok <- initiated_by_us_or_allowed(provider, identity),
         :ok <- record(ctx, provider, identity),
         {:ok, code} <- keep(ctx, provider, identity, params["RelayState"]) do
      {:redirect, URL.endpoint(ctx, "/sso/saml2/finish", code: code), ctx}
    else
      {:error, reason} when is_atom(reason) ->
        Logger.warning("authmk SSO: SAML response refused (#{reason})")
        Outcome.redirect_error(ctx, nil, :invalid_saml_response)

      _unknown_provider ->
        Outcome.redirect_error(ctx, nil, :sso_provider_not_found)
    end
  end

  defp expected(ctx, provider) do
    %{
      issuer: provider.saml.entity_id,
      certificates: provider.saml.certificates,
      audience: SAMLConfig.entity_id(ctx, provider),
      recipient: SAMLConfig.acs_url(ctx, provider),
      now: DateTime.utc_now(),
      clock_skew: saml_opts(ctx)[:clock_skew],
      decryption_keys: saml_opts(ctx)[:signing_keys],
      allow_aes_cbc: saml_opts(ctx)[:allow_aes_cbc]
    }
  end

  defp initiated_by_us_or_allowed(provider, %{in_response_to: nil}),
    do: if(provider.saml.allow_idp_initiated, do: :ok, else: {:error, :idp_initiated})

  defp initiated_by_us_or_allowed(_provider, _identity), do: :ok

  # Kept a little past its expiry, as long as clock skew lets it count.
  defp record(ctx, provider, identity) do
    until = DateTime.add(identity.expires_at, saml_opts(ctx)[:clock_skew])
    Replay.record(ctx, provider.saml.entity_id, identity.assertion_id, until)
  end

  defp keep(ctx, provider, identity, relay_state) do
    data = %{
      "provider_id" => provider.provider_id,
      "relay_state" => relay_state,
      "in_response_to" => identity.in_response_to,
      "name_id" => identity.name_id,
      "name_id_format" => identity.name_id_format,
      "session_index" => identity.session_index,
      "attributes" => identity.attributes
    }

    Verification.create(ctx, @code_purpose, data, @code_ttl)
  end

  @doc "GET /sso/saml2/finish"
  def finish(%Context{raw_params: params} = ctx) do
    with {:ok, data} <- Verification.consume(ctx, @code_purpose, params["code"]),
         %{type: "saml"} = provider <- Providers.find(ctx, data["provider_id"]) do
      case flow(ctx, provider, data) do
        {:ok, ctx, state} -> sign_in(ctx, provider, data, state)
        {:error, ctx, error} -> Outcome.redirect_error(ctx, nil, error.code)
      end
    else
      _invalid -> Outcome.redirect_error(ctx, nil, :invalid_saml_response)
    end
  end

  # The flow this browser started, answered by this response.
  defp flow(ctx, provider, %{"in_response_to" => nil} = data) do
    if provider.saml.allow_idp_initiated,
      do: {:ok, ctx, %{"callback_url" => relay_destination(ctx, data["relay_state"])}},
      else: {:error, ctx, Error.new(:state_mismatch)}
  end

  defp flow(ctx, provider, data) do
    with {:ok, ctx, state} <- State.finish(ctx, data["relay_state"]) do
      if state["sso_provider_id"] == provider.provider_id and
           Plug.Crypto.secure_compare(state["saml_request_id"] || "", data["in_response_to"]),
         do: {:ok, ctx, state},
         else: {:error, ctx, Error.new(:state_mismatch)}
    end
  end

  # IdP-initiated: RelayState may name where to go, if it's one of ours.
  defp relay_destination(ctx, relay_state) when is_binary(relay_state) do
    if Origin.check_redirect(ctx, relay_state) == :ok, do: relay_state
  end

  defp relay_destination(_ctx, _relay_state), do: nil

  defp sign_in(ctx, provider, data, state) do
    {info, profile} = Profile.from_identity(data, provider.saml.mapping)

    case Users.resolve(ctx, provider, info, profile) do
      {:ok, user, status} ->
        ctx |> Outcome.complete(user, status, state) |> remember_saml_session(provider, data)

      {:error, error} ->
        Outcome.redirect_error(ctx, state["error_callback_url"], error.code)
    end
  end

  # The session notes its IdP session, so single logout can find it.
  defp remember_saml_session(
         {:redirect, url, %Context{session: %{} = session} = ctx},
         provider,
         data
       ) do
    attrs = %{
      sso_provider_id: provider.provider_id,
      saml_name_id: data["name_id"],
      saml_session_index: data["session_index"]
    }

    case SessionStore.update(ctx, session, attrs) do
      {:ok, session} -> {:redirect, url, %{ctx | session: session}}
      {:error, _error} -> {:redirect, url, ctx}
    end
  end

  defp remember_saml_session(result, _provider, _data), do: result

  @doc "GET /sso/saml2/metadata/:provider_id"
  def metadata(%Context{raw_params: params} = ctx) do
    case Providers.find(ctx, params["provider_id"]) do
      %{type: "saml"} = provider ->
        keys = saml_opts(ctx)[:signing_keys]

        xml =
          Metadata.service_provider(%{
            entity_id: SAMLConfig.entity_id(ctx, provider),
            acs_url: SAMLConfig.acs_url(ctx, provider),
            slo_url: SAMLConfig.slo_url(ctx, provider),
            certificates: Enum.map(keys, & &1.certificate),
            signs_requests: keys != [],
            name_id_format: @name_id_format
          })

        {:html, 200, xml,
         Context.put_resp_header(ctx, "content-type", "application/samlmetadata+xml")}

      _not_saml ->
        {:error, Error.custom(:sso_provider_not_found, 404, "No such SAML provider")}
    end
  end

  defp signing_key(ctx) do
    case saml_opts(ctx)[:signing_keys] do
      [%{key: key} | _older] -> key
      [] -> nil
    end
  end

  defp saml_opts(ctx), do: Config.opts(ctx)[:saml]
end
