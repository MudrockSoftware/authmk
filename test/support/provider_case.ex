defmodule Authmk.Test.ProviderCase do
  @moduledoc false
  # Runs a built-in provider through a full sign-in against the fake
  # provider, and returns the user it created.
  #
  #     use Authmk.Test.ProviderCase, provider: :github
  #
  #     test "maps the profile", %{browser: browser} do
  #       user = sign_in(browser, routes: %{"/user" => %{...}})
  #       assert user["email"] == "ada@example.com"
  #     end

  use ExUnit.CaseTemplate

  alias Authmk.Test.{Browser, FakeProvider}

  using opts do
    provider = Keyword.fetch!(opts, :provider)
    provider_opts = Keyword.get(opts, :provider_opts, [])
    auth = Module.concat([Authmk.Test.Providers, Macro.camelize(Atom.to_string(provider)), Auth])

    quote do
      defmodule unquote(auth) do
        use Authmk,
          otp_app: :authmk,
          repo: Authmk.Test.Repo,
          base_url: "http://localhost:4000",
          background: :inline,
          rate_limit: [enabled: false],
          social_providers: [
            {unquote(provider),
             [client_id: "client-id", client_secret: "client-secret"] ++ unquote(provider_opts)}
          ],
          advanced: [http_options: [plug: {Req.Test, unquote(auth)}]]
      end

      use Authmk.EmulationCase, async: true

      import Authmk.Test.ProviderCase

      @moduletag auth: unquote(auth)
      @provider unquote(provider)

      # Signs in through the provider. `fake` options go to the fake provider:
      # `routes:` (path => JSON), `id_token:`, `jwks:`. Returns the
      # authorization URL and the signed-in user.
      def sign_in(browser, fake) do
        sign_in_through(browser, unquote(auth), @provider, fake)
      end
    end
  end

  @doc false
  def sign_in_through(browser, auth, provider, fake) do
    FakeProvider.stub(auth, fake)

    {browser, conn} =
      Browser.post(browser, "/sign-in/social", %{provider: provider, callback_url: "/done"})

    url =
      Browser.json(conn)["url"] || flunk("no authorization URL: #{inspect(Browser.json(conn))}")

    {browser, conn} = Browser.get(browser, "/callback/#{provider}", FakeProvider.approve(url))
    location = Browser.redirected_to(conn)
    if location != "/done", do: flunk("sign-in failed: #{location}")

    {_browser, conn} = Browser.get(browser, "/get-session")
    %{url: url, user: Browser.json(conn)["user"]}
  end
end
