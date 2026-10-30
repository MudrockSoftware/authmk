defmodule PhoenixAppWeb.SCIMTest do
  # SQLite takes one writer at a time: tests that write run one by one.
  use PhoenixAppWeb.ConnCase, async: false

  @admin %{email: "admin@acme.example", password: "correct horse", name: "Admin"}

  defp scim(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  test "an organization's directory provisions and deactivates its people", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/sign-up/email", @admin)

    org =
      conn
      |> recycle()
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/organization/create", %{name: "Acme", slug: "acme"})

    org_id = json_response(org, 200)["id"]

    connection =
      conn
      |> recycle()
      |> put_req_header("origin", "http://localhost:4000")
      |> post("/auth/scim/connections", %{organization_id: org_id, name: "Entra ID"})
      |> json_response(200)

    created =
      connection["token"]
      |> scim()
      |> post("/auth/scim/v2/Users", %{
        userName: "ada@acme.example",
        name: %{givenName: "Ada", familyName: "Lovelace"}
      })
      |> json_response(201)

    # Entra ID's way of deactivating.
    patched =
      connection["token"]
      |> scim()
      |> patch("/auth/scim/v2/Users/" <> created["id"], %{
        Operations: [%{op: "Replace", path: "active", value: "False"}]
      })
      |> json_response(200)

    assert patched["active"] == false
    assert "scim_wrong" |> scim() |> get("/auth/scim/v2/Users") |> response(401)
  end
end
