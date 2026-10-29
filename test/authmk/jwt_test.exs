defmodule Authmk.JWTTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query
  import Plug.Conn, only: [get_resp_header: 2]

  alias Authmk.Plugins.JWT
  alias Authmk.Test.Repo

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.JWT,
         rotation_interval: 60, grace_period: 60, jwks_path: "/.well-known/jwks.json"}
      ]
  end

  @moduletag auth: Auth

  defp token(browser) do
    {_browser, conn} = get(browser, "/token")
    json(conn)["token"]
  end

  defp jwks(browser) do
    {_browser, conn} = get(browser, "/.well-known/jwks.json")
    json(conn)["keys"]
  end

  defp age_keys(seconds) do
    module = Authmk.Store.module(Authmk.Context.new(Auth.config()), :jwks)
    Repo.update_all(module, set: [inserted_at: DateTime.add(DateTime.utc_now(), -seconds)])
  end

  test "tokens for the session, verifiable with the JWKS", %{browser: browser} do
    {browser, user} = sign_up(browser)
    token = token(browser)

    assert {:ok, claims} = JWT.verify(Auth, token)
    assert claims["sub"] == user["id"]
    assert claims["email"] == "ada@example.com"
    assert claims["iss"] == "http://localhost:4000"
    assert claims["aud"] == "http://localhost:4000"
    assert claims["exp"] - claims["iat"] == 900

    # Anyone with the JWKS can check it.
    [key] = jwks(browser)
    assert key["alg"] == "EdDSA"
    refute Map.has_key?(key, "d")
    assert {true, _jwt, _jws} = JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["EdDSA"], token)

    {_browser, conn} = get(browser, "/get-session")
    [header_token] = get_resp_header(conn, "set-auth-jwt")
    assert {:ok, _claims} = JWT.verify(Auth, header_token)
  end

  test "private keys are stored encrypted", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    _token = token(browser)

    [private_key] = Repo.all(from(k in "jwks", select: k.private_key))
    assert private_key =~ ~r/^v\d+\./
    refute private_key =~ "\"d\""
  end

  test "tampered, expired and foreign tokens are refused", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    token = token(browser)
    [header, payload, signature] = String.split(token, ".")

    forged_payload =
      payload
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()
      |> Map.put("sub", "someone-else")
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, %{code: :invalid_jwt}} =
             JWT.verify(Auth, Enum.join([header, forged_payload, signature], "."))

    assert {:error, %{code: :invalid_jwt}} = JWT.verify(Auth, "not.a.jwt")

    # Signed by someone else's key with the same kid.
    other = JOSE.JWK.generate_key({:okp, :Ed25519})
    kid = hd(jwks(browser))["kid"]
    claims = token |> JOSE.JWT.peek_payload() |> Map.fetch!(:fields)

    {_alg, foreign} =
      other |> JOSE.JWT.sign(%{"alg" => "EdDSA", "kid" => kid}, claims) |> JOSE.JWS.compact()

    assert {:error, _} = JWT.verify(Auth, foreign)

    # Expired, or for another audience, even when properly signed.
    private = private_key(browser)
    expired = Map.put(claims, "exp", System.system_time(:second) - 120)

    {_alg, expired_token} =
      private |> JOSE.JWT.sign(%{"alg" => "EdDSA", "kid" => kid}, expired) |> JOSE.JWS.compact()

    assert {:error, _} = JWT.verify(Auth, expired_token)

    elsewhere = Map.put(claims, "aud", "https://other.example")

    {_alg, elsewhere_token} =
      private |> JOSE.JWT.sign(%{"alg" => "EdDSA", "kid" => kid}, elsewhere) |> JOSE.JWS.compact()

    assert {:error, _} = JWT.verify(Auth, elsewhere_token)
  end

  test "keys rotate, and old tokens verify through the grace period", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    old_token = token(browser)
    [%{"kid" => old_kid}] = jwks(browser)

    # Past the rotation interval: a new key signs, the old one still verifies.
    age_keys(61)
    new_token = token(browser)
    assert JOSE.JWS.peek_protected(new_token) |> JSON.decode!() |> Map.fetch!("kid") != old_kid
    assert length(jwks(browser)) == 2
    assert {:ok, _} = JWT.verify(Auth, old_token)
    assert {:ok, _} = JWT.verify(Auth, new_token)

    # Past the grace period too: the old key is gone.
    age_keys(200)
    assert {:error, _} = JWT.verify(Auth, old_token)
  end

  defp private_key(_browser) do
    [private_key] = Repo.all(from(k in "jwks", select: k.private_key))
    {:ok, json} = Authmk.Crypto.decrypt(Auth.config(), "jwt-private-key", private_key)
    JOSE.JWK.from_map(JSON.decode!(json))
  end
end

defmodule Authmk.JWTAlgorithmsTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.JWT

  for algorithm <- ~w(ES256 ES384 ES512 RS256 PS256) do
    module = Module.concat(__MODULE__, algorithm)

    defmodule module do
      use Authmk,
        otp_app: :authmk,
        repo: Authmk.Test.Repo,
        base_url: "http://localhost:4000",
        background: :inline,
        rate_limit: [enabled: false],
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.JWT, algorithm: algorithm, encrypt_private_keys: false}
        ]
    end

    @tag auth: module
    test "#{algorithm}", %{browser: browser, auth: auth} do
      {browser, _user} = sign_up(browser)
      {browser, conn} = get(browser, "/token")
      token = json(conn)["token"]
      assert {:ok, %{"email" => "ada@example.com"}} = JWT.verify(auth, token)

      {_browser, conn} = get(browser, "/jwks")
      assert [%{"alg" => unquote(algorithm)}] = json(conn)["keys"]
    end
  end
end

defmodule Authmk.JWTCustomTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.JWT
  alias Authmk.Test.Repo

  defmodule MemoryKeys do
    # A key store in an ETS table, like an app keeping keys in a vault.
    @behaviour Authmk.Plugins.JWT.KeyStore

    @impl true
    def list(_ctx), do: :authmk_jwt_test_keys |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

    @impl true
    def insert(_ctx, attrs) do
      key =
        Map.merge(attrs, %{
          id: "key-#{System.unique_integer([:positive])}",
          inserted_at: DateTime.utc_now()
        })

      true = :ets.insert(:authmk_jwt_test_keys, {key.id, key})
      {:ok, key}
    end
  end

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.JWT,
         key_store: Authmk.JWTCustomTest.MemoryKeys,
         issuer: "https://auth.example.com",
         audience: ["https://api.example.com"],
         expires_in: 60,
         define_payload: &__MODULE__.payload/1,
         get_subject: &__MODULE__.subject/1}
      ]

    def payload(%{user: user}), do: %{plan: "pro", email: user.email}
    def subject(%{user: user}), do: "user:" <> to_string(user.id)
  end

  defmodule RemoteAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.JWT,
         algorithm: "ES256",
         sign: &__MODULE__.sign/2,
         remote_jwks_url: "https://kms.example.com/jwks"}
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]

    # Plays a KMS: one fixed key.
    def key, do: JOSE.JWK.from_map(Application.get_env(:authmk, :jwt_test_kms_key))

    def sign(claims, _ctx) do
      {_alg, token} =
        key()
        |> JOSE.JWT.sign(%{"alg" => "ES256", "kid" => "kms-1"}, claims)
        |> JOSE.JWS.compact()

      token
    end
  end

  @moduletag auth: Auth

  setup do
    if :ets.whereis(:authmk_jwt_test_keys) == :undefined,
      do: :ets.new(:authmk_jwt_test_keys, [:named_table, :public])

    :ok
  end

  test "custom payload, subject, issuer, audience and key store", %{browser: browser} do
    {browser, user} = sign_up(browser)
    {browser, conn} = get(browser, "/token")
    token = json(conn)["token"]

    assert {:ok, claims} = JWT.verify(Auth, token)
    assert claims["sub"] == "user:" <> user["id"]
    assert claims["plan"] == "pro"
    assert claims["iss"] == "https://auth.example.com"
    assert claims["aud"] == ["https://api.example.com"]
    refute Map.has_key?(claims, "name")
    assert claims["exp"] - claims["iat"] == 60

    {_browser, conn} = get(browser, "/jwks")
    assert [%{"kid" => "key-" <> _}] = json(conn)["keys"]
  end

  @tag auth: RemoteAuth
  test "signing elsewhere, verified with the remote JWKS", %{browser: browser} do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_kty, private} = JOSE.JWK.to_map(jwk)
    Application.put_env(:authmk, :jwt_test_kms_key, private)
    {_kty, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    Req.Test.stub(RemoteAuth, &Req.Test.json(&1, %{"keys" => [Map.put(public, "kid", "kms-1")]}))

    {browser, _user} = sign_up(browser)
    {browser, conn} = get(browser, "/token")
    assert {:ok, %{"email" => "ada@example.com"}} = JWT.verify(RemoteAuth, json(conn)["token"])

    # No keys are kept or served here.
    {_browser, conn} = get(browser, "/jwks")
    assert conn.status == 404
    assert Repo.aggregate("jwks", :count) == 0
  end
end
