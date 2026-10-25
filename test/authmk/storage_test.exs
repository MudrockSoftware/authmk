defmodule Authmk.StorageTest.SecondaryAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    secondary_storage: Authmk.Storage.ETS,
    user: [delete_user: [enabled: true]],
    rate_limit: [storage: :secondary_storage, rules: %{"/ok" => [window: 60, max: 2]}]

  @impl Authmk
  def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
end

defmodule Authmk.StorageTest.BothAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    secondary_storage: Authmk.Storage.ETS,
    session: [store_in_database: true, preserve_in_database: true],
    verification: [store_in_database: true]

  @impl Authmk
  def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
end

defmodule Authmk.StorageTest.DatabaseLimitAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.DatabaseRateLimit],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [storage: :database, rules: %{"/ok" => [window: 60, max: 2]}]

  @impl Authmk
  def send_reset_password(link, _ctx), do: send(self(), {:email, :reset_password, link})
end

defmodule Authmk.StorageTest do
  use Authmk.EmulationCase, async: true

  import Ecto.Query

  alias Authmk.Storage.ETS
  alias Authmk.StorageTest.{BothAuth, DatabaseLimitAuth, SecondaryAuth}
  alias Authmk.Test.Repo

  @moduletag auth: SecondaryAuth

  describe "secondary storage only" do
    test "sessions never touch the database", %{browser: browser} do
      {laptop, _user} = sign_up(browser)

      {phone, _conn} =
        post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

      assert Repo.aggregate("sessions", :count) == 0

      {_laptop, conn} = get(laptop, "/list-sessions")
      assert length(json(conn)) == 2

      {laptop, _conn} = post(laptop, "/revoke-other-sessions")
      {_phone, conn} = get(phone, "/get-session")
      assert json(conn) == nil
      {_laptop, conn} = get(laptop, "/get-session")
      assert json(conn)["user"]["email"] == "ada@example.com"
    end

    test "cached sessions follow user updates and deletion", %{browser: browser} do
      {laptop, _user} = sign_up(browser)

      {phone, _conn} =
        post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

      {laptop, _conn} = post(laptop, "/update-user", %{name: "Ada L."})
      {_phone, conn} = get(phone, "/get-session")
      assert json(conn)["user"]["name"] == "Ada L."

      {_laptop, _conn} = post(laptop, "/delete-user", %{password: "correct horse"})
      {_phone, conn} = get(phone, "/get-session")
      assert json(conn) == nil
    end

    test "reset tokens live in secondary storage and work once", %{browser: browser} do
      {_browser, _user} = sign_up(browser)
      {_browser, _conn} = post(browser, "/request-password-reset", %{email: "ada@example.com"})
      link = assert_email(:reset_password)
      assert Repo.aggregate("verifications", :count) == 0

      {_browser, conn} =
        post(browser, "/reset-password", %{token: link.token, new_password: "new password 1"})

      assert json(conn) == %{"status" => true}

      {_browser, conn} =
        post(browser, "/reset-password", %{token: link.token, new_password: "new password 2"})

      assert json(conn)["error"]["code"] == "invalid_token"
    end

    test "rate limits count in secondary storage", %{browser: browser} do
      statuses = for _ <- 1..3, do: elem(get(browser, "/ok"), 1).status
      assert statuses == [200, 200, 429]
    end
  end

  describe "database and secondary storage" do
    @describetag auth: BothAuth

    test "sessions are in both; the database answers when the cache is gone", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      assert Repo.aggregate("sessions", :count) == 1

      :ets.delete_all_objects(ETS.table(BothAuth))
      {_browser, conn} = get(browser, "/get-session")
      assert json(conn)["user"]["email"] == "ada@example.com"
    end

    test "revoked sessions keep their row, marked ended", %{browser: browser} do
      {browser, _user} = sign_up(browser)
      {browser, _conn} = post(browser, "/sign-out")

      [expires_at] = Repo.all(from(s in "sessions", select: s.expires_at))
      refute DateTime.after?(parse(expires_at), DateTime.utc_now())

      {_browser, conn} = get(browser, "/get-session")
      assert json(conn) == nil
    end
  end

  describe "database rate limits" do
    @describetag auth: DatabaseLimitAuth

    test "count in the rate_limits table", %{browser: browser} do
      statuses = for _ <- 1..3, do: elem(get(browser, "/ok"), 1).status
      assert statuses == [200, 200, 429]
      assert [3] = Repo.all(from(r in "rate_limits", select: r.count))
    end

    test "racing requests with one reset token: exactly one wins", %{browser: browser, repo: repo} do
      {_browser, _user} = sign_up(browser)
      {_browser, _conn} = post(browser, "/request-password-reset", %{email: "ada@example.com"})
      link = assert_email(:reset_password)

      statuses =
        1..5
        |> Enum.map(fn i ->
          Task.async(fn ->
            Repo.put_dynamic_repo(repo)

            {_browser, conn} =
              post(browser, "/reset-password", %{
                token: link.token,
                new_password: "new password #{i}"
              })

            conn.status
          end)
        end)
        |> Task.await_many()

      assert Enum.count(statuses, &(&1 == 200)) == 1, inspect(statuses)
    end
  end

  defp parse(%DateTime{} = datetime), do: datetime
  defp parse(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  defp parse(string) when is_binary(string) do
    {:ok, naive} = NaiveDateTime.from_iso8601(string)
    DateTime.from_naive!(naive, "Etc/UTC")
  end
end
