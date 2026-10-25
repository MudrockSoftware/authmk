defmodule Authmk.RedisStorageTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    secondary_storage: {Authmk.Storage.Redis, conn: :authmk_test_redix, prefix: "authmk-test:"}

  @impl Authmk
  def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
end

defmodule Authmk.RedisStorageTest do
  # Needs Redis or Valkey 7+: `docker compose up -d valkey`, then
  # `REDIS_URL=redis://localhost:6379 mix test`.
  use Authmk.EmulationCase, async: false

  alias Authmk.Storage.Redis
  alias Authmk.Test.Repo

  @moduletag :redis
  @moduletag auth: Authmk.RedisStorageTest.Auth

  setup_all do
    {:ok, _pid} = Redix.start_link(System.fetch_env!("REDIS_URL"), name: :authmk_test_redix)
    :ok
  end

  test "sessions and reset tokens live in Redis", %{browser: browser} do
    {laptop, _user} = sign_up(browser)

    {phone, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert Repo.aggregate("sessions", :count) == 0

    {laptop, _conn} = post(laptop, "/revoke-other-sessions")
    {_phone, conn} = get(phone, "/get-session")
    assert json(conn) == nil
    {_laptop, conn} = get(laptop, "/get-session")
    assert json(conn)["user"]["email"] == "ada@example.com"

    {_browser, _conn} = post(browser, "/request-password-reset", %{email: "ada@example.com"})
    link = assert_email(:reset_password)

    {_browser, conn} =
      post(browser, "/reset-password", %{token: link.token, new_password: "new password 1"})

    assert json(conn) == %{"status" => true}

    {_browser, conn} =
      post(browser, "/reset-password", %{token: link.token, new_password: "new password 2"})

    assert json(conn)["error"]["code"] == "invalid_token"
  end

  test "keys expire, and counters start once per key" do
    opts = [conn: :authmk_test_redix, prefix: "authmk-test:"]
    key = "counter-#{System.unique_integer([:positive])}"

    assert [1, 2, 3] == for(_ <- 1..3, do: Redis.increment(opts, key, 60))
    assert Redix.command!(:authmk_test_redix, ["TTL", "authmk-test:" <> key]) in 1..60

    :ok = Redis.put(opts, key <> ":v", "value", 1)
    assert Redis.get_and_delete(opts, key <> ":v") == "value"
    assert Redis.get(opts, key <> ":v") == nil
  end
end
