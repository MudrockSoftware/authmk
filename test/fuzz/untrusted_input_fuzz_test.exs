defmodule Authmk.Fuzz.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    trusted_origins: ["https://app.example.com"],
    background: :inline,
    rate_limit: [enabled: false],
    advanced: [ip_address_headers: ["x-forwarded-for"]]
end

defmodule Authmk.UntrustedInputFuzzTest do
  use Authmk.EmulationCase, async: true
  use ExUnitProperties

  @moduletag :fuzz
  @moduletag auth: Authmk.Fuzz.Auth

  @trusted ["http://localhost:4000", "https://app.example.com"]

  property "redirects only ever go to relative paths or trusted origins", %{browser: browser} do
    check all(url <- callback_url()) do
      {_browser, conn} = get(browser, "/verify-email", %{token: "bad", callback_url: url})

      case conn.status do
        302 ->
          location = redirected_to(conn)
          assert safe_location?(location), "redirected to #{inspect(location)}"

        403 ->
          assert json(conn)["error"]["code"] == "invalid_callback_url"

        # A blank URL means no redirect at all.
        400 ->
          assert String.trim(url) == ""
          assert json(conn)["error"]["code"] == "invalid_token"
      end
    end
  end

  property "any path and method gets a JSON answer, never a crash", %{browser: browser} do
    check all(
            segments <- list_of(string(:printable, max_length: 20), max_length: 4),
            method <- member_of([:get, :post])
          ) do
      path = "/" <> Enum.map_join(segments, "/", &URI.encode_www_form/1)
      {_browser, conn} = request(browser, method, path, %{})

      assert conn.status in [200, 302, 400, 401, 404, 422]
      assert conn.status == 302 or is_map(json(conn)) or is_nil(json(conn)) or is_list(json(conn))
    end
  end

  property "garbage proxy headers fall back to the socket address", %{browser: browser} do
    check all(header <- string(:printable, max_length: 60)) do
      browser = %{browser | headers: [{"x-forwarded-for", header}]}
      {_browser, conn} = get(browser, "/ok")
      assert conn.status == 200
    end
  end

  property "random session cookies never sign anyone in", %{browser: browser} do
    check all(token <- string(:printable, max_length: 64)) do
      browser = %{browser | cookies: %{"authmk.session_token" => token}}
      {_browser, conn} = get(browser, "/get-session")
      assert json(conn) == nil
    end
  end

  defp callback_url do
    one_of([
      string(:printable, max_length: 40),
      map(
        {member_of(["/", "//", "/\\", "http://", "https://", "javascript:", " /"]),
         string(:printable, max_length: 30)},
        fn
          {prefix, rest} -> prefix <> rest
        end
      ),
      map({member_of(@trusted), string(:printable, max_length: 20)}, fn {origin, rest} ->
        origin <> rest
      end)
    ])
  end

  defp safe_location?(location) do
    relative =
      String.starts_with?(location, "/") and not String.starts_with?(location, ["//", "/\\"])

    relative or Authmk.Origin.origin(location) in @trusted
  end
end
