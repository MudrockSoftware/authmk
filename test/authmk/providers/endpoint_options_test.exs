defmodule Authmk.Providers.EndpointOptionsTest do
  # Providers whose endpoints follow from their options: a tenant, an
  # environment, an instance.
  use Authmk.EmulationCase, async: true

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      rate_limit: [enabled: false],
      social_providers: [
        salesforce: [client_id: "id", client_secret: "secret", environment: :sandbox],
        salesforce_my_domain: [
          provider: Authmk.OAuth.Providers.Salesforce,
          client_id: "id",
          client_secret: "secret",
          login_url: "https://example.my.salesforce.com"
        ],
        paypal: [client_id: "id", client_secret: "secret", environment: :live],
        paybin: [client_id: "id", client_secret: "secret", issuer: "https://idp.example.com"],
        gitlab: [
          client_id: "id",
          client_secret: "secret",
          instance_url: "https://gitlab.example.com",
          authorize_url: "https://gitlab.example.com/custom/authorize"
        ]
      ]
  end

  @moduletag auth: Auth

  defp authorization_endpoint(browser, provider) do
    {_browser, conn} = post(browser, "/sign-in/social", %{provider: provider})
    uri = URI.parse(json(conn)["url"])
    "#{uri.scheme}://#{uri.host}#{uri.path}"
  end

  test "authorization URLs follow the options", %{browser: browser} do
    assert authorization_endpoint(browser, "salesforce") ==
             "https://test.salesforce.com/services/oauth2/authorize"

    assert authorization_endpoint(browser, "salesforce_my_domain") ==
             "https://example.my.salesforce.com/services/oauth2/authorize"

    assert authorization_endpoint(browser, "paypal") == "https://www.paypal.com/signin/authorize"
    assert authorization_endpoint(browser, "paybin") == "https://idp.example.com/oauth2/authorize"

    # An explicit URL wins over the derived one.
    assert authorization_endpoint(browser, "gitlab") ==
             "https://gitlab.example.com/custom/authorize"
  end

  test "token and profile endpoints follow them too" do
    providers = Auth.config().social_providers

    assert providers[:paypal].token_url == "https://api-m.paypal.com/v1/oauth2/token"

    assert providers[:salesforce].userinfo_url ==
             "https://test.salesforce.com/services/oauth2/userinfo"

    assert providers[:gitlab].userinfo_url == "https://gitlab.example.com/api/v4/user"
    assert providers[:paybin].token_url == "https://idp.example.com/oauth2/token"
  end
end
