defmodule Authmk.SecretTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.SecretTest do
  # Changes the AUTHMK_SECRET environment variable, which every test reads: not async.
  use Authmk.EmulationCase, async: false

  import ExUnit.CaptureLog

  alias Authmk.SecretTest.Auth

  @moduletag auth: Auth

  @old Base.url_encode64(:crypto.strong_rand_bytes(32))
  @new Base.url_encode64(:crypto.strong_rand_bytes(32))

  setup do
    on_exit(fn -> Application.delete_env(:authmk, Auth) end)
    :ok
  end

  test "rotating secrets keeps sessions valid until the old secret is removed", %{
    browser: browser
  } do
    restart_with(secrets: [{1, @old}])
    {browser, _user} = sign_up(browser)

    restart_with(secrets: [{2, @new}, {1, @old}])
    {browser, conn} = get(browser, "/get-session")
    assert json(conn)["user"]

    # A new sign-in uses the newest secret.
    {new_browser, _conn} =
      post(browser, "/sign-in/email", %{email: "ada@example.com", password: "correct horse"})

    assert "v2." <> _ = cookie(new_browser, "authmk.session_token")

    restart_with(secrets: [{2, @new}])
    {_browser, conn} = get(browser, "/get-session")
    assert json(conn) == nil
    {_browser, conn} = get(new_browser, "/get-session")
    assert json(conn)["user"]
  end

  test "AUTHMK_SECRETS sets versioned secrets" do
    with_env("AUTHMK_SECRETS", "3:#{@new}, 2:#{@old}", fn ->
      restart_with([])
      assert [{3, @new}, {2, @old}] = Auth.config().secrets
    end)
  end

  test "a short secret stops startup" do
    assert {:error, {{%ArgumentError{message: message}, _}, _}} =
             restart_with(secret: "too-short")

    assert message =~ "at least 32 characters"
  end

  test "a missing secret stops startup with instructions" do
    with_env("AUTHMK_SECRET", nil, fn ->
      assert {:error, {{%ArgumentError{message: message}, _}, _}} = restart_with([])
      assert message =~ "Set the AUTHMK_SECRET environment variable"
    end)
  end

  test "a low-entropy secret starts with a warning" do
    log = capture_log(fn -> restart_with(secret: String.duplicate("a", 40)) end)
    assert log =~ "looks low-entropy"
  end

  test "a malformed AUTHMK_SECRETS entry is named by position, never shown" do
    error =
      assert_raise ArgumentError, fn ->
        Authmk.Secrets.parse!("3:#{@new}, oops-#{@old}")
      end

    assert error.message =~ "position 2"
    refute error.message =~ @old
  end

  test "secrets never appear when the config is inspected" do
    restart_with(secret: @new)
    refute inspect(Auth.config()) =~ @new
  end

  defp restart_with(opts) do
    stop_supervised(Auth)
    Application.put_env(:authmk, Auth, opts)
    start_supervised(Auth)
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end
end
