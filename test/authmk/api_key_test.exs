defmodule Authmk.APIKeyTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Plug.FetchSession
  alias Authmk.Plugins.APIKey
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.APIKey,
         enable_sessions: true,
         configurations: [
           default: [prefix: "sk_", rate_limit: [enabled: false], enable_metadata: true],
           public: [
             prefix: "pk_",
             key_length: 32,
             require_name: true,
             disable_custom_expires_in: true,
             default_expires_in: 3600
           ],
           scoped: [default_permissions: %{"files" => ["read"]}]
         ]}
      ]
  end

  @moduletag auth: Auth

  defp user_id(browser) do
    {_browser, conn} = get(browser, "/get-session")
    json(conn)["user"]["id"]
  end

  defp create(browser, params \\ %{}) do
    {browser, conn} = post(browser, "/api-key/create", params)
    {browser, json(conn)}
  end

  describe "keys" do
    test "created once in clear, stored hashed, listed without the key", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, created} = create(browser, %{name: "CI", metadata: %{"team" => "infra"}})

      key = created["key"]
      assert "sk_" <> rest = key
      assert String.length(rest) == 64
      assert created["start"] == String.slice(key, 0, 6)
      assert created["metadata"] == %{"team" => "infra"}

      refute Enum.any?(Repo.all(from(k in "api_keys", select: k.key)), &(&1 == key))

      {browser, conn} = get(browser, "/api-key/list")
      assert [%{"name" => "CI"} = listed] = json(conn)
      refute Map.has_key?(listed, "key")

      {_browser, conn} = get(browser, "/api-key/get", %{id: created["id"]})
      assert json(conn)["start"] == created["start"]
    end

    test "verify: valid, unknown, disabled, expired", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, created} = create(browser)

      assert {:ok, %{name: nil}} = APIKey.verify(Auth, created["key"])
      assert {:error, %{code: :invalid_api_key}} = APIKey.verify(Auth, created["key"] <> "x")
      assert {:error, %{code: :invalid_api_key}} = APIKey.verify(Auth, nil)

      {_browser, conn} =
        post(browser, "/api-key/update", %{key_id: created["id"], enabled: false})

      assert json(conn)["enabled"] == false
      assert {:error, %{code: :api_key_disabled}} = APIKey.verify(Auth, created["key"])

      {:ok, _key} =
        APIKey.update(Auth, created["id"], %{
          enabled: true,
          expires_at: DateTime.add(DateTime.utc_now(), -1)
        })

      assert {:error, %{code: :api_key_expired}} = APIKey.verify(Auth, created["key"])
    end

    test "only the owner sees, changes or deletes a key", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, created} = create(browser)
      {eve, _user} = sign_up(Browser.new(Auth), %{email: "eve@example.com"})

      for {method, path, params} <- [
            {:get, "/api-key/get", %{id: created["id"]}},
            {:post, "/api-key/update", %{key_id: created["id"], name: "mine"}},
            {:post, "/api-key/delete", %{key_id: created["id"]}}
          ] do
        {_eve, conn} = request(eve, method, path, params)
        assert json(conn)["error"]["code"] == "api_key_not_found", path
      end

      {_browser, conn} = post(browser, "/api-key/delete", %{key_id: created["id"]})
      assert json(conn) == %{"success" => true}
      assert {:error, %{code: :invalid_api_key}} = APIKey.verify(Auth, created["key"])
    end

    test "configurations: prefix, length, required name, fixed expiry", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {browser, created} = create(browser, %{config_id: "public"})
      assert created["error"]["code"] == "name_required"

      {browser, created} = create(browser, %{config_id: "public", name: "Widget"})
      assert "pk_" <> rest = created["key"]
      assert String.length(rest) == 32
      {:ok, expires_at, _} = DateTime.from_iso8601(created["expires_at"])
      assert DateTime.diff(expires_at, DateTime.utc_now()) in 3590..3600

      {browser, created} = create(browser, %{config_id: "public", name: "W", expires_in: 86_400})
      assert created["error"]["code"] == "custom_expiry_disabled"

      {browser, created} = create(browser, %{expires_in: 60})
      assert created["error"]["code"] == "invalid_expires_in"

      {_browser, created} = create(browser, %{config_id: "nope"})
      assert created["error"]["code"] == "unknown_configuration"
    end
  end

  describe "limits and permissions" do
    test "permissions the key must have", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {:ok, %{key: key}} =
        APIKey.create(Auth, %{
          user_id: user_id(browser),
          permissions: %{"files" => ["read", "write"]}
        })

      assert {:ok, _key} = APIKey.verify(Auth, key, %{"files" => ["read"]})
      assert {:ok, _key} = APIKey.verify(Auth, key, %{files: [:read, :write]})

      assert {:error, %{code: :insufficient_api_key_permissions}} =
               APIKey.verify(Auth, key, %{"files" => ["delete"]})

      assert {:error, %{code: :insufficient_api_key_permissions}} =
               APIKey.verify(Auth, key, %{"billing" => ["read"]})
    end

    test "a configuration's default permissions", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {_browser, created} = create(browser, %{config_id: "scoped"})

      assert created["permissions"] == %{"files" => ["read"]}
      assert {:ok, _key} = APIKey.verify(Auth, created["key"], %{"files" => ["read"]})

      assert {:error, %{code: :insufficient_api_key_permissions}} =
               APIKey.verify(Auth, created["key"], %{"files" => ["write"]})
    end

    test "remaining uses run out, and refill", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {:ok, %{key: key, api_key: api_key}} =
        APIKey.create(Auth, %{
          user_id: user_id(browser),
          remaining: 2,
          refill_interval: 60,
          refill_amount: 3
        })

      assert {:ok, %{remaining: 1}} = APIKey.verify(Auth, key)
      assert {:ok, %{remaining: 0}} = APIKey.verify(Auth, key)
      assert {:error, %{code: :api_key_usage_exceeded}} = APIKey.verify(Auth, key)

      # A minute later.
      past = DateTime.add(DateTime.utc_now(), -61)

      module = Authmk.Store.module(Authmk.Context.new(Auth.config()), :api_key)
      Repo.update_all(where(module, id: ^api_key.id), set: [inserted_at: past])

      assert {:ok, %{remaining: 2}} = APIKey.verify(Auth, key)
    end

    test "uses can't be overspent by concurrent requests", %{browser: browser, repo: repo} do
      {browser, _user} = sign_up(browser)
      {:ok, %{key: key}} = APIKey.create(Auth, %{user_id: user_id(browser), remaining: 5})

      results =
        1..20
        |> Task.async_stream(fn _ ->
          Repo.put_dynamic_repo(repo)
          APIKey.verify(Auth, key)
        end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 5
    end

    test "rate limits", %{browser: browser} do
      {browser, _user} = sign_up(browser)

      {:ok, %{key: key}} =
        APIKey.create(Auth, %{
          user_id: user_id(browser),
          rate_limit_enabled: true,
          rate_limit_max: 2,
          rate_limit_time_window: 60
        })

      assert {:ok, _key} = APIKey.verify(Auth, key)
      assert {:ok, _key} = APIKey.verify(Auth, key)
      assert {:error, %{code: :api_key_rate_limited}} = APIKey.verify(Auth, key)
    end

    test "expired keys are cleaned up", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {:ok, %{api_key: old}} = APIKey.create(Auth, %{user_id: user_id(browser)})
      {:ok, _new} = APIKey.create(Auth, %{user_id: user_id(browser)})

      {:ok, _old} =
        APIKey.update(Auth, old.id, %{expires_at: DateTime.add(DateTime.utc_now(), -1)})

      assert APIKey.delete_expired(Auth) == 1
      assert Repo.aggregate("api_keys", :count) == 1
    end
  end

  describe "sessions from keys" do
    test "a user's key in the header signs requests in, but never as fresh", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, created} = create(browser)
      {_browser, _conn} = post(browser, "/sign-out")

      with_key = %{Browser.new(Auth) | headers: [{"x-api-key", created["key"]}]}
      {_with_key, conn} = get(with_key, "/get-session")
      assert json(conn)["user"]["email"] == "ada@example.com"

      {_with_key, conn} = post(with_key, "/delete-user", %{password: "correct horse"})
      assert json(conn)["error"]["code"] in ["session_not_fresh", "feature_disabled"]

      bad = %{Browser.new(Auth) | headers: [{"x-api-key", "sk_nope"}]}
      {_bad, conn} = get(bad, "/get-session")
      assert conn.status == 401
    end

    test "in the app's own pipeline too", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {_browser, created} = create(browser)

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("x-api-key", created["key"])
        |> FetchSession.call(FetchSession.init(auth: Auth))

      assert conn.assigns.current_user.email == "ada@example.com"

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("x-api-key", "sk_nope")
        |> FetchSession.call(FetchSession.init(auth: Auth))

      assert conn.assigns.current_user == nil
    end
  end
end

defmodule Authmk.APIKeyOrganizationTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.APIKey
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Organization, send_invitation_email: &__MODULE__.send_invitation/2},
        Authmk.Plugins.APIKey
      ]

    def send_invitation(%{id: id}, _ctx), do: send(self(), {:invitation, id})
  end

  @moduletag auth: Auth

  test "an organization's keys, managed by those allowed to", %{browser: _browser} do
    {owner, _user} = sign_up(Browser.new(Auth))
    {owner, conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})
    org = json(conn)

    {owner, conn} = post(owner, "/api-key/create", %{name: "Deploy", organization_id: org["id"]})
    created = json(conn)
    assert created["organization_id"] == org["id"]
    assert {:ok, %{organization_id: org_id, user_id: nil}} = APIKey.verify(Auth, created["key"])
    assert org_id == org["id"]

    {owner, _conn} =
      post(owner, "/organization/invite-member", %{email: "grace@example.com", role: "member"})

    assert_received {:invitation, id}
    {grace, _user} = sign_up(Browser.new(Auth), %{email: "grace@example.com"})
    {grace, _conn} = post(grace, "/organization/accept-invitation", %{invitation_id: id})

    # Members may not touch the organization's keys.
    {grace, conn} = get(grace, "/api-key/list", %{organization_id: org["id"]})
    assert conn.status == 403
    {_grace, conn} = post(grace, "/api-key/delete", %{key_id: created["id"]})
    assert conn.status == 403

    {owner, conn} = get(owner, "/api-key/list", %{organization_id: org["id"]})
    assert [%{"name" => "Deploy"}] = json(conn)
    # The owner's own keys are separate.
    {_owner, conn} = get(owner, "/api-key/list")
    assert json(conn) == []

    {_stranger, conn} =
      post(
        sign_up(Browser.new(Auth), %{email: "eve@example.com"}) |> elem(0),
        "/api-key/create",
        %{organization_id: org["id"]}
      )

    assert json(conn)["error"]["code"] == "not_a_member"
  end
end

defmodule Authmk.APIKeyStorageTest do
  # Keys in secondary storage, alone or next to the database.
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.APIKey
  alias Authmk.Test.Repo

  for mode <- [:secondary_storage, :both] do
    module = Module.concat(__MODULE__, Macro.camelize(Atom.to_string(mode)))

    defmodule module do
      use Authmk,
        otp_app: :authmk,
        repo: Authmk.Test.Repo,
        base_url: "http://localhost:4000",
        background: :inline,
        rate_limit: [enabled: false],
        secondary_storage: Authmk.Storage.ETS,
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.APIKey,
           storage: mode,
           enable_sessions: true,
           custom_key_generator: &Authmk.APIKeyStorageTest.generate/1,
           custom_key_validator: &Authmk.APIKeyStorageTest.valid?/2}
        ]
    end

    @tag auth: module
    test "#{mode}: create, verify, count uses, list, delete", %{browser: browser, auth: auth} do
      {browser, user} = sign_up(browser)

      {:ok, %{key: key, api_key: api_key}} =
        APIKey.create(auth, %{user_id: user["id"], remaining: 2, rate_limit_enabled: false})

      assert "custom_" <> _ = key
      assert {:ok, %{remaining: 1}} = APIKey.verify(auth, key)
      assert {:ok, %{remaining: 0}} = APIKey.verify(auth, key)
      assert {:error, %{code: :api_key_usage_exceeded}} = APIKey.verify(auth, key)

      # Keys the validator turns down never reach storage.
      assert {:error, %{code: :invalid_api_key}} = APIKey.verify(auth, "rejected")

      {browser, conn} = get(browser, "/api-key/list")
      assert [%{"id" => id}] = json(conn)
      assert id == api_key.id

      database_rows = Repo.aggregate("api_keys", :count)
      assert database_rows == if(unquote(mode) == :both, do: 1, else: 0)

      {_browser, conn} = post(browser, "/api-key/delete", %{key_id: id})
      assert json(conn) == %{"success" => true}
      assert {:error, %{code: :invalid_api_key}} = APIKey.verify(auth, key)
    end
  end

  def generate(%{length: length}),
    do: "custom_" <> Base.url_encode64(:crypto.strong_rand_bytes(length), padding: false)

  def valid?(key, _ctx), do: String.starts_with?(key, "custom_")
end
