defmodule Authmk.Plugins.SSO.SAMLLogout do
  @moduledoc false
  # SAML single logout, both ways, for providers with an `slo_url`:
  #
  #   * POST /sso/saml2/logout: the user signs out here; the session ends
  #     at once, and they're sent to the provider with a LogoutRequest. Its
  #     LogoutResponse comes back to /sso/saml2/slo/:provider_id, and must
  #     answer that request (RelayState names it), then the user goes on to
  #     `callback_url`.
  #   * The provider signs the user out everywhere: its LogoutRequest comes
  #     to /sso/saml2/slo/:provider_id, every session that sign-in made for
  #     that NameID (and SessionIndex) ends, and a LogoutResponse goes back.
  #
  # Messages from the provider must be signed (Authmk.Plugins.SSO.SAML.Logout).
  # Sessions are found by their SAML fields: in the database, so single
  # logout from the provider needs sessions stored there.

  import Ecto.Query, only: [dynamic: 2]

  alias Authmk.{Context, Cookies, Log, Origin, SessionStore, Store, Verification}
  alias Authmk.Plugins.SSO.{Config, Outcome, Providers, SAMLConfig}
  alias Authmk.Plugins.SSO.SAML.{Logout, RedirectBinding, Request}

  @purpose "sso-saml-logout"
  @max_message 64_000

  @doc "POST /sso/saml2/logout"
  def start(%Context{params: params, session: session} = ctx) do
    with :ok <- Origin.check_redirect(ctx, params.callback_url) do
      provider = saml_provider(ctx, session)
      :ok = SessionStore.delete(ctx, session)
      ctx = %{Cookies.clear_session(ctx) | session: nil, user: nil}

      if provider && provider.saml.slo_url && session.saml_name_id,
        do: send_request(ctx, provider, session, params.callback_url),
        else: {:ok, %{redirect: false}, ctx}
    end
  end

  defp saml_provider(ctx, session) do
    case Map.get(session, :sso_provider_id) do
      nil -> nil
      id -> with %{type: "saml"} = provider <- Providers.find(ctx, id), do: provider
    end
  end

  defp send_request(ctx, provider, session, callback_url) do
    id = Request.new_id()

    data = %{
      "request_id" => id,
      "provider_id" => provider.provider_id,
      "callback_url" => callback_url
    }

    with {:ok, relay_state} <- Verification.create(ctx, @purpose, data, 600) do
      xml =
        Logout.request_xml(%{
          id: id,
          issuer: SAMLConfig.entity_id(ctx, provider),
          destination: provider.saml.slo_url,
          name_id: session.saml_name_id,
          name_id_format: nil,
          session_index: session.saml_session_index
        })

      url =
        RedirectBinding.url(
          provider.saml.slo_url,
          "SAMLRequest",
          xml,
          relay_state,
          signing_key(ctx)
        )

      {:ok, %{redirect: true, url: url}, ctx}
    end
  end

  @doc "GET and POST /sso/saml2/slo/:provider_id"
  def slo(%Context{raw_params: params} = ctx) do
    with %{type: "saml"} = provider <- Providers.find(ctx, params["provider_id"]),
         {:ok, kind, fields, relay_state} <- read(ctx, provider, params) do
      handle(ctx, provider, kind, fields, relay_state)
    else
      {:error, reason} when is_atom(reason) ->
        Log.warning("authmk SSO: SAML logout message refused (#{reason})")
        Outcome.redirect_error(ctx, nil, :invalid_saml_logout)

      _unknown_provider ->
        Outcome.redirect_error(ctx, nil, :sso_provider_not_found)
    end
  end

  # The redirect binding signs the query; posted messages sign themselves.
  defp read(%Context{conn: conn} = ctx, provider, params) do
    param = if params["SAMLRequest"], do: "SAMLRequest", else: "SAMLResponse"
    expected = expected(ctx, provider)

    case conn.method do
      "GET" ->
        with {:ok, xml, relay_state} <-
               RedirectBinding.verify(conn.query_string, param, provider.saml.certificates),
             {:ok, kind, fields} <- Logout.parse(xml, Map.put(expected, :signed, true)),
             do: {:ok, kind, fields, relay_state}

      "POST" ->
        with {:ok, xml} <- posted(params[param]),
             {:ok, kind, fields} <- Logout.parse(xml, Map.put(expected, :signed, false)),
             do: {:ok, kind, fields, params["RelayState"]}
    end
  end

  defp posted(encoded) when is_binary(encoded) and byte_size(encoded) <= @max_message do
    case encoded |> String.replace(~r/\s+/, "") |> Base.decode64() do
      {:ok, xml} -> {:ok, xml}
      :error -> {:error, :invalid_encoding}
    end
  end

  defp posted(_encoded), do: {:error, :invalid_encoding}

  defp expected(ctx, provider) do
    %{
      issuer: provider.saml.entity_id,
      destination: SAMLConfig.slo_url(ctx, provider),
      certificates: provider.saml.certificates,
      now: DateTime.utc_now(),
      clock_skew: Config.opts(ctx)[:saml][:clock_skew]
    }
  end

  # The provider signs the user out: so do we, and say so.
  defp handle(ctx, provider, :request, fields, relay_state) do
    :ok = end_sessions(ctx, provider, fields)

    case provider.saml.slo_url do
      nil ->
        {:redirect, "/", ctx}

      slo_url ->
        xml =
          Logout.response_xml(%{
            id: Request.new_id(),
            issuer: SAMLConfig.entity_id(ctx, provider),
            destination: slo_url,
            in_response_to: fields.id
          })

        {:redirect,
         RedirectBinding.url(slo_url, "SAMLResponse", xml, relay_state, signing_key(ctx)), ctx}
    end
  end

  # The answer to our request: then on to where the user was going.
  defp handle(ctx, provider, :response, fields, relay_state) do
    with {:ok, data} <- Verification.consume(ctx, @purpose, relay_state),
         true <- data["provider_id"] == provider.provider_id,
         true <- Plug.Crypto.secure_compare(data["request_id"], fields.in_response_to || "") do
      destination = data["callback_url"] || "/"

      if fields.success,
        do: {:redirect, destination, ctx},
        else: Outcome.redirect_error(ctx, destination, :saml_logout_failed)
    else
      _no -> Outcome.redirect_error(ctx, nil, :invalid_saml_logout)
    end
  end

  defp end_sessions(ctx, provider, %{name_id: name_id, session_indexes: indexes}) do
    provider_id = provider.provider_id

    condition =
      if indexes == [],
        do: dynamic([s], s.sso_provider_id == ^provider_id and s.saml_name_id == ^name_id),
        else:
          dynamic(
            [s],
            s.sso_provider_id == ^provider_id and s.saml_name_id == ^name_id and
              s.saml_session_index in ^indexes
          )

    ctx
    |> Store.all(:session, condition, limit: 1000)
    |> Enum.each(&SessionStore.delete(ctx, &1))
  end

  defp signing_key(ctx) do
    case Config.opts(ctx)[:saml][:signing_keys] do
      [%{key: key} | _older] -> key
      [] -> nil
    end
  end
end
