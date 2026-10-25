defmodule Authmk.PrimaryKeyTest.UuidV7Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    primary_key: :uuid_v7,
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.PrimaryKeyTest.StringIdAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    primary_key: {:string, {Authmk.Test.Ids, :generate, []}},
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.PrimaryKeyTest.MixedAuth do
  # Integer user ids, with sessions kept only in secondary storage.
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    primary_key: :id,
    schema: [session: [primary_key: :uuid_v7]],
    secondary_storage: Authmk.Storage.ETS,
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.PrimaryKeyTest do
  use Authmk.EmulationCase, async: true

  @moduletag auth: Authmk.PrimaryKeyTest.UuidV7Auth

  test "uuid_v7 ids are time-ordered UUIDs, in every table", %{browser: browser} do
    {browser, user} = sign_up(browser)
    {_browser, conn} = get(browser, "/get-session")
    session = json(conn)["session"]

    for id <- [user["id"], session["id"]] do
      assert <<_::binary-size(14), "7", _::binary>> = id
    end

    assert session["user_id"] == user["id"]
  end

  @tag auth: Authmk.PrimaryKeyTest.StringIdAuth
  test "custom string ids come from the app's function", %{browser: browser} do
    {browser, user} = sign_up(browser)
    assert "id_" <> _ = user["id"]

    {_browser, conn} = get(browser, "/list-accounts")
    assert [%{"id" => "id_" <> _, "user_id" => user_id}] = json(conn)
    assert user_id == user["id"]
  end

  @tag auth: Authmk.PrimaryKeyTest.MixedAuth
  test "models can mix kinds: integer users, uuid sessions", %{browser: browser} do
    {browser, user} = sign_up(browser)
    assert is_integer(user["id"])

    {browser, conn} = get(browser, "/get-session")
    assert <<_::binary-size(14), "7", _::binary>> = json(conn)["session"]["id"]
    assert json(conn)["session"]["user_id"] == user["id"]

    {_browser, conn} = post(browser, "/revoke-sessions")
    assert json(conn) == %{"status" => true}
  end

  test "integer session ids can't live only in secondary storage" do
    assert_raise ArgumentError, ~r/can't have integer ids/, fn ->
      defmodule IntegerSecondaryAuth do
        use Authmk,
          otp_app: :authmk,
          repo: Authmk.Test.Repo,
          primary_key: :id,
          secondary_storage: Authmk.Storage.ETS,
          base_url: "http://localhost:4000"
      end

      Authmk.Config.load(IntegerSecondaryAuth)
    end
  end
end
