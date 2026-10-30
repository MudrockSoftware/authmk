defmodule Authmk.Plugins.JWT do
  @moduledoc """
  JWTs from sessions, for services that verify tokens on their own (with
  the JWKS) instead of calling your app.

      use Authmk, plugins: [{Authmk.Plugins.JWT, algorithm: "ES256", expires_in: 900}], ...

  | Method | Path | Session |
  |---|---|---|
  | GET | `/token` | required |
  | GET | `/jwks` (`jwks_path`) | none |

  `GET /token` answers with `%{token: jwt}` for the signed-in user, and
  `GET /get-session` carries one in the `set-auth-jwt` header too. Tokens
  have `iss` and `aud` (the base URL unless set), `sub` (the user's id),
  `iat`, `exp` and, by default, the user's public fields; change them with
  `define_payload` and `get_subject`.

  Keys are made on first use and stored with the private half encrypted
  (`encrypt_private_keys`). With `rotation_interval`, a new key takes over
  after that many seconds, and old keys stay in the JWKS for `grace_period`
  so the tokens they signed still verify. With `sign` and
  `remote_jwks_url`, keys live somewhere else (a KMS).

  Check tokens in Elixir with `verify/2`.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.JWT.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{BaseURL, Context, Endpoint, Error, Serializer}
  alias Authmk.OAuth.HTTP
  alias Authmk.Plugins.JWT.{Keys, Options}
  alias Authmk.Storage.ETS

  @header "set-auth-jwt"
  @clock_skew 60
  @remote_cache_ttl 3600

  @impl true
  def init(opts) do
    opts = NimbleOptions.validate!(opts, Options.schema())

    if opts[:remote_jwks_url] && is_nil(opts[:sign]),
      do:
        raise(
          ArgumentError,
          "Authmk.Plugins.JWT: remote_jwks_url needs `sign`, to sign with the remote keys"
        )

    opts
  end

  @impl true
  def schema(_opts) do
    %{
      jwks: [
        plural: "jwks",
        fields: [
          public_key: [type: :text, required: true, input: false],
          private_key: [type: :text, required: true, returned: false, redact: true, input: false],
          algorithm: [type: :string, required: true, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(opts) do
    token =
      Endpoint.new(
        name: :jwt_token,
        method: :get,
        path: "/token",
        handler: {__MODULE__, :token},
        session: :required
      )

    jwks =
      Endpoint.new(
        name: :jwks,
        method: :get,
        path: opts[:jwks_path] || "/jwks",
        handler: {__MODULE__, :jwks},
        cors: true
      )

    if opts[:remote_jwks_url], do: [token], else: [token, jwks]
  end

  # Sessions read through get-session come with a token.
  @impl true
  def on_response(conn, %Context{endpoint: %{name: :get_session}, session: %{}, user: %{}} = ctx) do
    case issue(ctx) do
      {:ok, token} ->
        conn
        |> Plug.Conn.put_resp_header(@header, token)
        |> Plug.Conn.put_resp_header("access-control-expose-headers", @header)

      {:error, _error} ->
        conn
    end
  end

  def on_response(conn, _ctx), do: conn

  @doc false
  def token(ctx) do
    with {:ok, token} <- issue(ctx), do: {:ok, %{token: token}, ctx}
  end

  @doc false
  def jwks(ctx) do
    keys = ctx |> Keys.published(opts(ctx)) |> Enum.map(&Keys.jwks_entry/1)
    {:ok, %{keys: keys}, ctx}
  end

  @doc """
  Checks a token from this app: signed by one of its published keys (or the
  remote JWKS) with the configured algorithm, not expired, and with the
  expected issuer and audience. Returns the claims.
  """
  @spec verify(module(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def verify(auth, token) do
    config = auth.config()
    ctx = %{Context.new(config) | base_url: server_base_url(config)}
    opts = opts(ctx)

    with {:ok, claims} <- verified_claims(ctx, token),
         :ok <- check_claims(ctx, opts, claims) do
      {:ok, claims}
    else
      _invalid -> {:error, Error.custom(:invalid_jwt, 401, "The token isn't valid")}
    end
  end

  @doc false
  # The claims of a token signed by one of this app's keys, with no check
  # of what they say: for plugins with their own rules (the OAuth provider).
  @spec verified_claims(Context.t(), String.t()) :: {:ok, map()} | :error
  def verified_claims(ctx, token) when is_binary(token) do
    opts = opts(ctx)

    with {:ok, kid} <- kid(token),
         {:ok, jwk} <- verification_key(ctx, opts, kid),
         {true, %JOSE.JWT{fields: claims}, _jws} <-
           JOSE.JWT.verify_strict(jwk, [opts[:algorithm]], token) do
      {:ok, claims}
    else
      _invalid -> :error
    end
  rescue
    _malformed -> :error
  end

  def verified_claims(_ctx, _token), do: :error

  @doc false
  # Signs `claims` as they are, with this app's current key.
  # `header` adds JOSE header fields, like `typ`.
  @spec sign_claims(Context.t(), map(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def sign_claims(ctx, claims, header \\ %{}), do: sign(ctx, opts(ctx), claims, header)

  @doc false
  # The signing algorithm and where the public keys are, for metadata.
  @spec algorithm(Context.t()) :: String.t()
  def algorithm(ctx), do: opts(ctx)[:algorithm]

  @doc false
  @spec jwks_url(Context.t()) :: String.t()
  def jwks_url(ctx) do
    opts = opts(ctx)
    opts[:remote_jwks_url] || Authmk.URL.endpoint(ctx, opts[:jwks_path] || "/jwks")
  end

  @doc false
  # A token for the context's user and session, for plugins that hand out
  # tokens (device authorization).
  def issue(%Context{user: user, session: session} = ctx) do
    opts = opts(ctx)
    now = System.system_time(:second)
    subject = %{user: user, session: session}

    claims =
      ctx
      |> payload(opts, subject)
      |> Map.merge(%{
        "sub" =>
          to_string(if(opts[:get_subject], do: opts[:get_subject].(subject), else: user.id)),
        "iss" => issuer(ctx, opts),
        "aud" => audience(ctx, opts),
        "iat" => now,
        "exp" => now + opts[:expires_in]
      })

    sign(ctx, opts, claims)
  end

  defp payload(ctx, opts, subject) do
    if opts[:define_payload],
      do:
        subject
        |> opts[:define_payload].()
        |> Map.new(fn {key, value} -> {to_string(key), value} end),
      else: ctx |> Serializer.user(subject.user) |> JSON.encode!() |> JSON.decode!()
  end

  defp sign(ctx, opts, claims, header \\ %{}) do
    case opts[:sign] do
      nil ->
        with {:ok, key} <- Keys.current(ctx, opts) do
          jwk = Keys.private_jwk(ctx, key, opts)
          header = Map.merge(header, %{"alg" => opts[:algorithm], "kid" => key.id})

          {_alg, token} =
            jwk
            |> JOSE.JWT.sign(header, claims)
            |> JOSE.JWS.compact()

          {:ok, token}
        end

      sign ->
        {:ok, sign.(claims, ctx)}
    end
  end

  defp kid(token) do
    case token |> JOSE.JWS.peek_protected() |> JSON.decode!() do
      %{"kid" => kid} when is_binary(kid) -> {:ok, kid}
      _no_kid -> :error
    end
  end

  defp verification_key(ctx, opts, kid) do
    entries =
      case opts[:remote_jwks_url] do
        nil -> ctx |> Keys.published(opts) |> Enum.map(&Keys.jwks_entry/1)
        url -> remote_keys(ctx, url)
      end

    case Enum.find(entries, &(&1["kid"] == kid)) do
      nil -> :error
      entry -> {:ok, JOSE.JWK.from_map(entry)}
    end
  end

  # The remote JWKS, cached for an hour.
  defp remote_keys(%Context{config: config} = ctx, url) do
    table = [table: ETS.table(config.auth)]
    key = "jwt-remote-jwks:" <> url

    case ETS.get(table, key) do
      nil -> fetch_remote_keys(ctx, table, key, url)
      json -> JSON.decode!(json)
    end
  end

  defp fetch_remote_keys(ctx, table, key, url) do
    case HTTP.get(ctx, url) do
      {:ok, 200, %{"keys" => keys}} when is_list(keys) ->
        :ok = ETS.put(table, key, JSON.encode!(keys), @remote_cache_ttl)
        keys

      _failed ->
        []
    end
  end

  defp check_claims(ctx, opts, claims) do
    now = System.system_time(:second)
    expected_audiences = List.wrap(audience(ctx, opts))

    if is_integer(claims["exp"]) and claims["exp"] > now - @clock_skew and
         claims["iss"] == issuer(ctx, opts) and
         Enum.any?(List.wrap(claims["aud"]), &(&1 in expected_audiences)),
       do: :ok,
       else: :error
  end

  # With dynamic base URLs, set `issuer` and `audience`: tokens can't name
  # every host.
  defp server_base_url(config) do
    case BaseURL.resolve(config, nil) do
      {:ok, base_url} -> base_url
      _none -> nil
    end
  end

  defp issuer(%Context{base_url: base_url}, opts), do: opts[:issuer] || base_url
  defp audience(%Context{base_url: base_url}, opts), do: opts[:audience] || base_url

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
