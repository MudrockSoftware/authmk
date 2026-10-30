defmodule Authmk.RequestPipelineTest.Plugin do
  @moduledoc false
  # Exercises every stage a plugin can hook into.
  use Authmk.Plugin

  alias Authmk.{Endpoint, Error}

  @impl true
  def endpoints(_opts) do
    [
      Endpoint.new(name: :boom, method: :get, path: "/boom", handler: {__MODULE__, :boom}),
      Endpoint.new(
        name: :members_only,
        method: :get,
        path: "/members-only",
        handler: {__MODULE__, :members_only},
        session: :required,
        middleware: [{__MODULE__, :require_member}]
      )
    ]
  end

  @impl true
  def on_request(%{conn: conn} = ctx) do
    if Plug.Conn.get_req_header(conn, "x-block") == ["yes"],
      do: {:halt, Error.custom(:blocked, 403, "Blocked by a plugin")},
      else: {:cont, ctx}
  end

  @impl true
  def on_response(conn, _ctx), do: Plug.Conn.put_resp_header(conn, "x-handled-by", "authmk")

  def require_member(%{user: user} = ctx) do
    if String.ends_with?(user.email, "@members.example"),
      do: {:cont, ctx},
      else: {:halt, Error.new(:forbidden)}
  end

  def boom(_ctx), do: raise("kaboom")
  def members_only(ctx), do: {:ok, %{welcome: ctx.user.email}, ctx}
end

defmodule Authmk.RequestPipelineTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword, Authmk.RequestPipelineTest.Plugin],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]

  @impl Authmk
  def on_api_error(error, _ctx), do: send(self(), {:api_error, error})
end

defmodule Authmk.RequestPipelineTest.ReraiseAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.RequestPipelineTest.Plugin],
    base_url: "http://localhost:4000",
    background: :inline,
    errors: [rescue: false]
end

defmodule Authmk.RequestPipelineTest do
  use Authmk.EmulationCase, async: true

  import ExUnit.CaptureLog

  @moduletag auth: Authmk.RequestPipelineTest.Auth

  test "on_request can stop any request, with a plugin's own error code", %{browser: browser} do
    {_browser, conn} = get(%{browser | headers: [{"x-block", "yes"}]}, "/ok")

    assert conn.status == 403

    assert json(conn)["error"] == %{
             "code" => "blocked",
             "message" => "Blocked by a plugin",
             "details" => %{}
           }
  end

  test "on_response changes every response", %{browser: browser} do
    {_browser, conn} = get(browser, "/ok")
    assert Plug.Conn.get_resp_header(conn, "x-handled-by") == ["authmk"]
  end

  test "endpoint middleware runs after the session loads", %{browser: browser} do
    {outsider, _user} = sign_up(browser)
    {_browser, conn} = get(outsider, "/members-only")
    assert json(conn)["error"]["code"] == "forbidden"

    {member, _user} = sign_up(browser, %{email: "grace@members.example"})
    {_browser, conn} = get(member, "/members-only")
    assert json(conn) == %{"welcome" => "grace@members.example"}
  end

  test "errors reach on_api_error", %{browser: browser} do
    {_browser, _conn} =
      post(browser, "/sign-in/email", %{email: "nobody@example.com", password: "whatever1"})

    assert_received {:api_error, %Authmk.Error{code: :invalid_credentials}}
  end

  test "a crash is logged and answered with internal_error, without details", %{browser: browser} do
    log =
      capture_log(fn ->
        {_browser, conn} = get(browser, "/boom")
        assert conn.status == 500
        assert json(conn)["error"]["code"] == "internal_error"
        refute conn.resp_body =~ "kaboom"
      end)

    assert log =~ "kaboom"
    assert_received {:api_error, %RuntimeError{message: "kaboom"}}
  end

  @tag auth: Authmk.RequestPipelineTest.ReraiseAuth
  test "with errors: [rescue: false], crashes reach the app's error handling", %{browser: browser} do
    assert_raise RuntimeError, "kaboom", fn -> get(browser, "/boom") end
  end

  test "the error page: themed, escaped, and its files served", %{browser: browser} do
    hostile = "</script><script>alert(1)</script>"

    {_browser, conn} =
      get(browser, "/error", %{error: hostile, error_description: "<img src=x onerror=alert(1)>"})

    assert conn.status == 400
    assert ["text/html" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]

    # The request's text only reaches the page as escaped JSON data.
    [data] =
      Regex.run(
        ~r{<script type="application/json" id="authmk-page">(.*?)</script>}s,
        conn.resp_body, capture: :all_but_first)

    refute data =~ "<"

    assert %{"name" => "error", "code" => ^hostile, "message" => "<img src=x onerror=alert(1)>"} =
             JSON.decode!(data)

    refute conn.resp_body =~ "<script>alert(1)"
    refute conn.resp_body =~ "<img src=x"

    {_browser, conn} = get(browser, "/error", %{error: "invalid_token"})
    assert conn.resp_body =~ "The link or code is invalid or has expired"

    # The page's own files, under authmk's path.
    [_, script] = Regex.run(~r{"\./(_app/immutable/entry/start\.[^"]+)"}, conn.resp_body)
    {_browser, asset} = get(browser, "/" <> script)
    assert asset.status == 200
    {_browser, missing} = get(browser, "/_app/nope.js")
    assert missing.status == 404
  end
end
