defmodule Authmk.PluginTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword, {Authmk.Test.GreetingPlugin, greeting: "Merhaba"}],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    disabled_paths: ["/verify-password"]

  @impl Authmk
  def after_endpoint(:greet, _ctx, {:ok, body, ctx}),
    do: {:ok, Map.put(body, :seen_by_app, true), ctx}

  def after_endpoint(_endpoint, _ctx, result), do: result
end

defmodule Authmk.PluginTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Test.Repo

  @moduletag auth: Authmk.PluginTest.Auth

  test "plugin endpoints, options, schema and hooks work together", %{browser: browser} do
    {browser, user} = sign_up(browser)
    assert user["nickname"] == "friend"

    {_browser, conn} = post(browser, "/greet", %{punctuation: "?"})

    assert json(conn) == %{"message" => "Merhaba, friend?", "seen_by_app" => true}
    assert Repo.aggregate("greeting_logs", :count) == 1
  end

  test "a before hook can stop a request", %{browser: browser} do
    {_browser, conn} =
      post(browser, "/sign-up/email", %{
        email: "eve@blocked.example",
        password: "correct horse",
        name: "Eve"
      })

    assert json(conn)["error"]["code"] == "forbidden"
    assert Repo.aggregate("users", :count) == 0
  end

  test "disabled paths are gone", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, conn} = post(browser, "/verify-password", %{password: "correct horse"})
    assert conn.status == 404
  end

  test "deleting a user cascades to plugin tables", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, _conn} = post(browser, "/greet")

    Repo.delete_all("users")
    assert Repo.aggregate("greeting_logs", :count) == 0
  end

  test "endpoints emit telemetry", %{browser: browser} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:authmk, :endpoint, :stop]])
    {_browser, _conn} = get(browser, "/ok")

    assert_received {[:authmk, :endpoint, :stop], ^ref, %{duration: _},
                     %{endpoint: :ok, result: :ok}}
  end
end
