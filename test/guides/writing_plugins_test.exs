defmodule MyApp.Auth.ThemePlugin do
  # The plugin from guides/writing-plugins.md, verbatim. Keep them in sync.
  use Authmk.Plugin

  @impl true
  def init(opts),
    do:
      NimbleOptions.validate!(opts, themes: [type: {:list, :string}, default: ["light", "dark"]])

  @impl true
  def schema(_opts) do
    %{user: [fields: [theme: [type: :string, default: "light", input: false]]]}
  end

  @impl true
  def endpoints(_opts) do
    [
      Authmk.Endpoint.new(
        name: :set_theme,
        method: :post,
        path: "/theme",
        handler: {__MODULE__, :set_theme},
        session: :required,
        params: [theme: [type: :string, required: true]],
        rate_limit: [window: 60, max: 10]
      )
    ]
  end

  def set_theme(ctx) do
    themes = Authmk.Context.plugin_opts(ctx, __MODULE__)[:themes]

    if ctx.params.theme in themes do
      with {:ok, user} <- Authmk.Store.update(ctx, :user, ctx.user, %{theme: ctx.params.theme}) do
        {:ok, %{theme: user.theme}, %{ctx | user: user}}
      end
    else
      {:error, Authmk.Error.custom(:unknown_theme, 422, "That theme doesn't exist")}
    end
  end

  @impl true
  def before_endpoint(:sign_up_email, ctx) do
    if ctx.raw_params["theme"] in [nil, "light", "dark"],
      do: {:cont, ctx},
      else: {:halt, Authmk.Error.new(:bad_request)}
  end

  def before_endpoint(_endpoint, ctx), do: {:cont, ctx}
end

defmodule Authmk.Guides.WritingPluginsTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [
      Authmk.Plugins.EmailPassword,
      {MyApp.Auth.ThemePlugin, themes: ["light", "dark", "dim"]}
    ],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.Guides.WritingPluginsTest do
  use Authmk.EmulationCase, async: true

  @moduletag auth: Authmk.Guides.WritingPluginsTest.Auth

  test "the guide's plugin works as described", %{browser: browser} do
    {browser, user} = sign_up(browser)
    assert user["theme"] == "light"

    {browser, conn} = post(browser, "/theme", %{theme: "dim"})
    assert json(conn) == %{"theme" => "dim"}

    {_browser, conn} = post(browser, "/theme", %{theme: "neon"})
    assert json(conn)["error"]["code"] == "unknown_theme"

    {_browser, conn} =
      post(browser, "/sign-up/email", %{
        email: "b@example.com",
        password: "correct horse",
        name: "B",
        theme: "neon"
      })

    assert json(conn)["error"]["code"] == "bad_request"
  end
end
