defmodule PlugApp.SCIMTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PlugApp.ConnCase, async: false

  @admin %{email: "admin@acme.example", password: "correct horse", name: "Admin"}

  defp scim(method, path, token, body \\ nil) do
    conn(method, "/auth/scim/v2" <> path, body && JSON.encode!(body))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/scim+json")
    |> call()
  end

  test "an organization's directory provisions and deactivates its people" do
    admin = cookies(post_json("/auth/sign-up/email", @admin))

    org_id =
      json(post_json("/auth/organization/create", %{name: "Acme", slug: "acme"}, admin))["id"]

    %{"token" => token} =
      json(post_json("/auth/scim/connections", %{organization_id: org_id, name: "Okta"}, admin))

    conn =
      scim(:post, "/Users", token, %{
        userName: "ada@acme.example",
        name: %{givenName: "Ada", familyName: "Lovelace"}
      })

    assert conn.status == 201
    %{"id" => id, "displayName" => "Ada Lovelace"} = json(conn)

    assert json(
             scim(:get, "/Users?filter=" <> URI.encode(~s(userName eq "ada@acme.example")), token)
           )["totalResults"] == 1

    patch = %{Operations: [%{op: "replace", path: "active", value: false}]}
    assert json(scim(:patch, "/Users/" <> id, token, patch))["active"] == false

    assert scim(:get, "/Users", "scim_wrong").status == 401
  end
end
