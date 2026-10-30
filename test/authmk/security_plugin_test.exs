defmodule Authmk.SecurityPluginTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.Security
  alias Authmk.Plugins.Security.ProofOfWork
  alias Authmk.Test.{Browser, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      advanced: [ip_address_headers: ["x-forwarded-for"]],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Security,
         credential_stuffing: [max_accounts: 3, max_failures: 10],
         sign_up_limit: [max: 2, window: 3600],
         velocity: [list_sessions: [max: 2, window: 60]],
         email: [check_mx: true, resolve_mx: &__MODULE__.mx/1],
         geo_lookup: &__MODULE__.geo/1,
         geo_blocking: [blocked_countries: ["KP"]],
         impossible_travel: [action: :block],
         blocked_ips: ["203.0.113.0/24"],
         block_bots: true,
         on_event: &__MODULE__.event/2}
      ]

    def mx("no-mail.example"), do: :error
    def mx(_domain), do: {:ok, ["mx.example"]}

    def geo("10.0.0.1"), do: {:ok, %{country: "DE", latitude: 52.52, longitude: 13.40}}
    def geo("10.0.0.2"), do: {:ok, %{country: "US", latitude: 40.71, longitude: -74.0}}
    def geo("10.0.0.3"), do: {:ok, %{country: "KP", latitude: 39.03, longitude: 125.75}}
    def geo(_ip), do: :error

    def event(event, _ctx), do: send(self(), {:security, event.type})
  end

  defmodule PowAuth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.Security,
         proof_of_work: [endpoints: [:sign_up_email], difficulty: 8],
         email: [unique_canonical: true]}
      ]
  end

  @moduletag auth: Auth

  defp from(ip, browser \\ Browser.new(Auth)),
    do: %{browser | headers: [{"x-forwarded-for", ip}, {"user-agent", "Mozilla/5.0"}]}

  defp sign_up_from(ip, email) do
    {_browser, conn} =
      post(from(ip), "/sign-up/email", %{email: email, password: "correct horse", name: "Ada"})

    conn
  end

  defp sign_in_from(browser, ip, email, password \\ "correct horse") do
    post(from(ip, browser), "/sign-in/email", %{email: email, password: password})
  end

  test "an IP failing for many accounts is blocked, even with a right password" do
    assert sign_up_from("10.9.0.1", "ada@example.com").status == 200

    for email <- ["a@example.com", "b@example.com", "c@example.com"] do
      {_browser, conn} = sign_in_from(Browser.new(Auth), "10.9.9.9", email, "wrong")
      assert conn.status == 401
    end

    assert_received {:security, :credential_stuffing}
    {_browser, conn} = sign_in_from(Browser.new(Auth), "10.9.9.9", "ada@example.com")
    assert json(conn)["error"]["code"] == "too_many_attempts"

    # Elsewhere, fine.
    {_browser, conn} = sign_in_from(Browser.new(Auth), "10.9.9.8", "ada@example.com")
    assert conn.status == 200
  end

  test "sign-ups per IP, and emails that won't do" do
    assert sign_up_from("10.8.0.1", "one@example.com").status == 200
    assert sign_up_from("10.8.0.1", "two@example.com").status == 200

    assert json(sign_up_from("10.8.0.1", "three@example.com"))["error"]["code"] ==
             "too_many_sign_ups"

    assert_received {:security, :sign_up_limit}

    assert json(sign_up_from("10.8.0.2", "x@mailinator.com"))["error"]["code"] ==
             "disposable_email"

    assert json(sign_up_from("10.8.0.2", "x@sub.yopmail.com"))["error"]["code"] ==
             "disposable_email"

    assert json(sign_up_from("10.8.0.2", "x@no-mail.example"))["error"]["code"] ==
             "email_cannot_receive_mail"
  end

  test "bots, blocked IPs and regions get nowhere", %{browser: browser} do
    {_browser, conn} =
      post(%{browser | headers: [{"user-agent", "curl/8.4.0"}]}, "/sign-up/email", %{
        email: "a@example.com",
        password: "correct horse",
        name: "A"
      })

    assert json(conn)["error"]["code"] == "bot_blocked"

    {_browser, conn} = get(from("203.0.113.77"), "/ok")
    assert json(conn)["error"]["code"] == "ip_blocked"

    {_browser, conn} = get(from("10.0.0.3"), "/ok")
    assert json(conn)["error"]["code"] == "region_blocked"
    assert_received {:security, :region_blocked}
  end

  test "a sign-in from the other side of the world minutes later is blocked" do
    assert sign_up_from("10.0.0.1", "ada@example.com").status == 200

    {_browser, conn} = sign_in_from(Browser.new(Auth), "10.0.0.2", "ada@example.com")
    assert json(conn)["error"]["code"] == "sign_in_blocked"
    assert_received {:security, :impossible_travel}

    # From near the last place, fine.
    {_browser, conn} = sign_in_from(Browser.new(Auth), "10.0.0.1", "ada@example.com")
    assert conn.status == 200
  end

  test "velocity limits per user, and sign-ins dated for inactivity checks" do
    {browser, conn} =
      post(from("10.7.0.1"), "/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse",
        name: "Ada"
      })

    assert conn.status == 200

    {browser, _conn} = get(browser, "/list-sessions")
    {browser, _conn} = get(browser, "/list-sessions")
    {_browser, conn} = get(browser, "/list-sessions")
    assert json(conn)["error"]["code"] == "velocity_limited"

    assert Security.inactive_users(Auth, 30) == []

    Repo.update_all("users",
      set: [last_sign_in_at: DateTime.add(DateTime.utc_now(), -40 * 86_400)]
    )

    assert [%{email: "ada@example.com"}] = Security.inactive_users(Auth, 30)
  end

  @tag auth: PowAuth
  test "proof-of-work before sign-up, once per challenge", %{browser: browser} do
    {browser, conn} =
      post(browser, "/sign-up/email", %{
        email: "ada@example.com",
        password: "correct horse",
        name: "Ada"
      })

    assert json(conn)["error"]["code"] == "proof_of_work_required"

    {browser, conn} = get(browser, "/security/challenge")
    %{"challenge" => challenge, "difficulty" => 8} = json(conn)
    nonce = ProofOfWork.solve(challenge, 8)
    solved = %{browser | headers: [{"x-pow-challenge", challenge}, {"x-pow-nonce", nonce}]}

    {_browser, conn} =
      post(solved, "/sign-up/email", %{
        email: "a.da+news@gmail.com",
        password: "correct horse",
        name: "Ada"
      })

    assert conn.status == 200

    # Used up; and a solved one can't be forged.
    {_browser, conn} =
      post(solved, "/sign-up/email", %{
        email: "bob@example.com",
        password: "correct horse",
        name: "Bob"
      })

    assert json(conn)["error"]["code"] == "proof_of_work_required"

    # The same mailbox, spelled another way.
    {_browser, conn} = get(browser, "/security/challenge")
    challenge = json(conn)["challenge"]

    solved = %{
      browser
      | headers: [
          {"x-pow-challenge", challenge},
          {"x-pow-nonce", ProofOfWork.solve(challenge, 8)}
        ]
    }

    {_browser, conn} =
      post(solved, "/sign-up/email", %{
        email: "ada@googlemail.com",
        password: "correct horse",
        name: "Ada"
      })

    assert json(conn)["error"]["code"] == "email_already_used"
  end
end
