defmodule Authmk.PhoenixTest do
  # A Phoenix app (test/support/phoenix.ex) using authmk's router macros,
  # LiveView hooks and components. LiveViews run in their own processes, so
  # the repo takes its default name and these tests run one at a time.
  use Authmk.EmulationCase, async: false

  # Phoenix.ConnTest's get/post, not the emulation Browser's.
  import Authmk.Test.Browser, only: []
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Authmk.{Context, LiveView, Sessions, Testing}
  alias Authmk.Plugins.Organization
  alias Authmk.Test.Phoenix.{Auth, Endpoint}

  @endpoint Endpoint
  @moduletag auth: Auth
  @moduletag global_repo: true

  setup do
    start_supervised!(Endpoint)
    %{conn: build_conn()}
  end

  defp user(attrs \\ []) do
    Testing.create_user(
      Auth,
      Keyword.merge(
        [email: "ada@example.com", name: "Ada", password: "correct horse battery"],
        attrs
      )
    )
  end

  # What a browser does with an HTML form: post its fields, as a form, from
  # the page it's on.
  defp submit(conn, html, selector, values) do
    form = html |> LazyHTML.from_document() |> LazyHTML.query(selector)
    [action] = LazyHTML.attribute(form, "action")

    fields =
      form
      |> LazyHTML.query("input[type=hidden]")
      |> Enum.map(fn input ->
        {hd(LazyHTML.attribute(input, "name")), hd(LazyHTML.attribute(input, "value"))}
      end)

    body = URI.encode_query(fields ++ Enum.to_list(values))

    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("origin", "http://localhost:4000")
    |> put_req_header("referer", "http://localhost:4000/sign-in")
    |> dispatch(@endpoint, :post, action, body)
  end

  describe "LiveView hooks" do
    test "pages for signed-in users send others to sign in, and back", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/settings")

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "signed out"

      ada = user()
      signed_in = Testing.sign_in(conn, Auth, ada)

      {:ok, view, html} = live(signed_in, "/settings")
      assert html =~ ~s(<p id="email">ada@example.com</p>)
      assert render(view) =~ ~s(<p id="principal">ada@example.com</p>)

      # Sign-in pages send signed-in users on.
      assert {:error, {:redirect, %{to: "/settings"}}} = live(signed_in, "/sign-in")
    end

    test "every mount reads the session: revoked ones are signed out", %{conn: conn} do
      ada = user()
      signed_in = Testing.sign_in(conn, Auth, ada)
      {:ok, _view, _html} = live(signed_in, "/settings")

      :ok = Sessions.revoke_all(Context.new(Auth.config()), ada.id)

      # The cookie is still there; the session behind it isn't.
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(signed_in, "/settings")
    end

    test "the LiveView session carries the token's hash and a socket ID", %{conn: conn} do
      signed_in = Testing.sign_in(conn, Auth, user())
      session = LiveView.session(signed_in, Auth)

      [token_hash] = [session["authmk_session"]]

      refute Enum.any?(Plug.Conn.fetch_cookies(signed_in).req_cookies, fn {_name, value} ->
               value =~ token_hash
             end)

      assert session["live_socket_id"] == "authmk_session:" <> token_hash
      assert LiveView.session(conn, Auth) == %{}

      [stored] = Testing.list_sessions(Auth, Testing.get_user_by(Auth, email: "ada@example.com"))
      assert LiveView.socket_id(stored) == session["live_socket_id"]
    end
  end

  describe "components" do
    test "sign in with the form: wrong password back to the page, then in", %{conn: conn} do
      user()
      {:ok, _view, html} = live(conn, "/sign-in")

      wrong = submit(conn, html, "form", email: "ada@example.com", password: "nope")
      assert wrong.status == 303
      assert redirected_to(wrong, 303) == "/sign-in?error=invalid_credentials"

      {:ok, _view, html} = live(conn, "/sign-in?error=invalid_credentials")
      assert html =~ "Invalid email or password"

      ok = submit(conn, html, "form", email: "ada@example.com", password: "correct horse battery")
      assert redirected_to(ok, 303) == "/settings"

      {:ok, _view, html} = ok |> recycle() |> live("/settings")
      assert html =~ "ada@example.com"
    end

    test "account settings: rename, switch organization, sign out", %{conn: conn} do
      ada = user()
      {:ok, _member} = Organization.add_member(Auth, create_organization("Acme"), ada.id, "owner")
      signed_in = Testing.sign_in(conn, Auth, ada)
      {:ok, _view, html} = live(signed_in, "/settings")

      renamed = submit(signed_in, html, "form[action='/auth/update-user']", name: "Ada Lovelace")
      assert redirected_to(renamed, 303) == "/settings"
      assert Testing.get_user_by(Auth, email: "ada@example.com").name == "Ada Lovelace"

      [organization] = Organization.list_for_user(Auth, ada)

      switched =
        submit(signed_in, html, "form[action='/auth/organization/set-active']",
          organization_id: organization.id
        )

      assert redirected_to(switched, 303) == "/settings"
      [session] = Testing.list_sessions(Auth, ada)
      assert to_string(session.active_organization_id) == to_string(organization.id)

      signed_out = submit(signed_in, html, "form[action='/auth/sign-out']", %{})
      assert redirected_to(signed_out, 303) == "/"
      assert Testing.list_sessions(Auth, ada) == []
    end

    test "other sessions are listed with a sign-out button, this one isn't", %{conn: conn} do
      ada = user()
      %{session: other} = Testing.create_session(Auth, ada)
      signed_in = Testing.sign_in(conn, Auth, ada)
      {:ok, _view, html} = live(signed_in, "/settings")

      assert html =~ "This device"

      revoked =
        submit(signed_in, html, "form[action='/auth/revoke-session']", %{})

      assert redirected_to(revoked, 303) == "/settings"
      refute Enum.any?(Testing.list_sessions(Auth, ada), &(&1.id == other.id))
      assert length(Testing.list_sessions(Auth, ada)) == 1
    end

    test "sign up, forget the password, reset it, all with forms", %{conn: conn} do
      html = render_component(&Authmk.Components.sign_up_form/1, redirect_to: "/settings")

      signed_up =
        submit(conn, html, "form",
          name: "Grace",
          email: "grace@example.com",
          password: "a long password"
        )

      assert redirected_to(signed_up, 303) == "/settings"
      assert Testing.get_user_by(Auth, email: "grace@example.com").name == "Grace"

      html =
        render_component(&Authmk.Components.forgot_password_form/1,
          redirect_to: "/forgot-password?sent=true",
          reset_url: "/reset-password"
        )

      # The same answer for an unknown email: no telling who has an account.
      unknown = submit(conn, html, "form", email: "nobody@example.com")
      assert redirected_to(unknown, 303) == "/forgot-password?sent=true"
      sent = submit(conn, html, "form", email: "grace@example.com")
      assert redirected_to(sent, 303) == "/forgot-password?sent=true"

      link = assert_email(:reset_password)
      landing = get(conn, URI.parse(link.url).path <> "?" <> URI.parse(link.url).query)
      "/reset-password?token=" <> token = redirected_to(landing)

      html =
        render_component(&Authmk.Components.reset_password_form/1,
          token: token,
          redirect_to: "/sign-in"
        )

      reset = submit(conn, html, "form", new_password: "another long password")
      assert redirected_to(reset, 303) == "/sign-in"

      html = render_component(&Authmk.Components.sign_in_form/1, redirect_to: "/settings")

      ok =
        submit(conn, html, "form", email: "grace@example.com", password: "another long password")

      assert redirected_to(ok, 303) == "/settings"
    end

    test "a second factor sends the form to its own page", %{conn: conn} do
      user(two_factor_enabled: true)
      {:ok, _view, html} = live(conn, "/sign-in")

      challenged =
        submit(conn, html, "form", email: "ada@example.com", password: "correct horse battery")

      assert redirected_to(challenged, 303) == "/two-factor"

      html = render_component(&Authmk.Components.two_factor_form/1, redirect_to: "/settings")
      wrong = challenged |> recycle() |> submit(html, "form", code: "000000")
      assert redirected_to(wrong, 303) =~ "/sign-in?error="
    end

    test "a social sign-in button goes to the provider", %{conn: conn} do
      html = """
      <form method="post" action="/auth/sign-in/social">
        <input type="hidden" name="provider" value="github" />
        <input type="hidden" name="callback_url" value="/settings" />
        <input type="hidden" name="authmk_redirect" value="/settings" />
      </form>
      """

      to_github = submit(conn, html, "form", %{})
      assert "https://github.com/login/oauth/authorize?" <> _ = redirected_to(to_github, 303)
    end

    test "forms only go to safe places", %{conn: conn} do
      user()

      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("origin", "http://localhost:4000")
        |> dispatch(
          @endpoint,
          :post,
          "/auth/sign-in/email",
          URI.encode_query(
            email: "ada@example.com",
            password: "correct horse battery",
            authmk_redirect: "https://evil.example/"
          )
        )

      assert conn.status == 403
      assert JSON.decode!(conn.resp_body)["error"]["code"] == "invalid_callback_url"
      refute Map.has_key?(conn.resp_cookies, "authmk.session_token")
    end

    test "the passkey script is served next to the endpoints", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(src="/auth/passkey.js")

      script = get(conn, "/auth/passkey.js")
      assert script.status == 200
      assert script.resp_body =~ "parseRequestOptionsFromJSON"
    end
  end

  defp create_organization(name) do
    {:ok, organization} =
      Authmk.Store.insert(Context.new(Auth.config()), :organization, %{
        name: name,
        slug: String.downcase(name)
      })

    organization.id
  end
end
