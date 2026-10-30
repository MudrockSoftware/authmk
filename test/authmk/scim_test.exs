defmodule Authmk.SCIMTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.SCIM
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Organization,
        {Authmk.Plugins.SCIM,
         can_manage: &__MODULE__.admin?/3, group_roles: &__MODULE__.group_role/1}
      ]

    def admin?(_action, _organization_id, %{user: user}), do: user.email == "admin@acme.example"
    def group_role("Admins"), do: "admin"
    def group_role(_group), do: nil
  end

  @moduletag auth: Auth

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"

  # An organization with a SCIM connection; returns the directory's client.
  setup %{browser: browser} do
    {admin, _user} = sign_up(browser, %{email: "admin@acme.example"})
    {admin, conn} = post(admin, "/organization/create", %{name: "Acme", slug: "acme"})
    org_id = json(conn)["id"]
    {admin, conn} = post(admin, "/scim/connections", %{organization_id: org_id, name: "Okta"})
    %{"token" => "scim_" <> _ = token} = json(conn)
    %{directory: directory(token), org_id: org_id, admin: admin}
  end

  defp directory(token),
    do: %{Browser.new(Auth) | origin: nil, headers: [{"authorization", "Bearer " <> token}]}

  defp scim(directory, method, path, body \\ %{}) do
    {_directory, conn} = Browser.request(directory, method, "/scim/v2" <> path, body)
    {conn.status, if(conn.resp_body == "", do: nil, else: json(conn))}
  end

  defp ada(overrides \\ %{}) do
    Map.merge(
      %{
        "schemas" => [@user_schema],
        "userName" => "ada@acme.example",
        "name" => %{"givenName" => "Ada", "familyName" => "Lovelace"},
        "emails" => [%{"value" => "ada@acme.example", "primary" => true}],
        "externalId" => "okta-1",
        "active" => true
      },
      overrides
    )
  end

  defp role(org_id, user_id) do
    ctx = Authmk.Context.new(Auth.config())
    Authmk.Store.get_by(ctx, :member, organization_id: org_id, user_id: user_id).role
  end

  test "a directory provisions people into the organization", %{
    directory: directory,
    org_id: org_id
  } do
    {_directory, conn} = Browser.request(directory, :post, "/scim/v2/Users", ada())
    assert conn.status == 201
    assert ["application/scim+json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    created = json(conn)

    assert %{
             "id" => id,
             "userName" => "ada@acme.example",
             "active" => true,
             "displayName" => "Ada Lovelace"
           } = created

    assert created["meta"]["location"] == "http://localhost:4000/auth/scim/v2/Users/" <> id

    user = Authmk.Testing.get_user_by(Auth, email: "ada@acme.example")
    assert role(org_id, user.id) == "member"

    assert {200, %{"externalId" => "okta-1"}} = scim(directory, :get, "/Users/" <> id)

    # Filters compare case-insensitively.
    assert {200, %{"totalResults" => 1}} =
             scim(directory, :get, "/Users", %{filter: ~s(userName eq "ADA@acme.example")})

    assert {200, %{"totalResults" => 1}} =
             scim(directory, :get, "/Users", %{
               filter: ~s(name.familyName sw "love" and active eq true)
             })

    assert {200, %{"totalResults" => 0}} =
             scim(directory, :get, "/Users", %{filter: ~s(userName co "100%")})

    assert {400, %{"scimType" => "invalidFilter"}} =
             scim(directory, :get, "/Users", %{filter: ~s(password eq "x")})

    assert {400, %{"scimType" => "invalidFilter"}} =
             scim(directory, :get, "/Users", %{filter: ~s(userName eq)})

    # The same person twice, or an email with an account already: refused.
    assert {409, %{"scimType" => "uniqueness"}} = scim(directory, :post, "/Users", ada())
    {_bob, _user} = sign_up(Browser.new(Auth), %{email: "bob@acme.example"})
    bob = ada(%{"userName" => "bob@acme.example", "emails" => [%{"value" => "bob@acme.example"}]})
    assert {409, %{"scimType" => "uniqueness"}} = scim(directory, :post, "/Users", bob)
  end

  test "deactivated people can't sign in, and their sessions end", %{directory: directory} do
    {201, %{"id" => id}} = scim(directory, :post, "/Users", ada())
    user = Authmk.Testing.get_user_by(Auth, email: "ada@acme.example")
    signed_in = Plug.Test.conn(:get, "/") |> Authmk.Testing.sign_in(Auth, user)
    assert [_session] = Authmk.Testing.list_sessions(Auth, user)

    # Entra ID's way: capitalized op, boolean as a string.
    patch = %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
      "Operations" => [%{"op" => "Replace", "path" => "active", "value" => "False"}]
    }

    assert {200, %{"active" => false}} = scim(directory, :patch, "/Users/" <> id, patch)
    assert Authmk.Testing.list_sessions(Auth, user) == []

    assert_raise ArgumentError, ~r/account_deactivated/, fn ->
      Authmk.Testing.sign_in(signed_in, Auth, user)
    end

    # Back on.
    patch = %{
      "Operations" => [
        %{"op" => "replace", "value" => %{"active" => true, "name.givenName" => "Augusta"}}
      ]
    }

    assert {200, %{"active" => true, "name" => %{"givenName" => "Augusta"}}} =
             scim(directory, :patch, "/Users/" <> id, patch)

    assert %Plug.Conn{} = Authmk.Testing.sign_in(signed_in, Auth, user)

    # Deleted: gone from the directory's view, and kept out.
    assert {204, nil} = scim(directory, :delete, "/Users/" <> id)
    assert {404, _} = scim(directory, :get, "/Users/" <> id)
    assert_raise ArgumentError, fn -> Authmk.Testing.sign_in(signed_in, Auth, user) end

    # Provisioned again: the same user, back in.
    assert {201, %{"id" => ^id, "active" => true}} = scim(directory, :post, "/Users", ada())
    assert Authmk.Testing.get_user_by(Auth, email: "ada@acme.example").id == user.id
    assert %Plug.Conn{} = Authmk.Testing.sign_in(signed_in, Auth, user)
  end

  test "another directory can't provision someone this one deleted", %{
    directory: directory,
    admin: admin,
    org_id: org_id
  } do
    {201, %{"id" => id}} = scim(directory, :post, "/Users", ada())
    assert {204, nil} = scim(directory, :delete, "/Users/" <> id)

    {_admin, conn} = post(admin, "/scim/connections", %{organization_id: org_id, name: "Entra"})
    other = directory(json(conn)["token"])
    assert {409, %{"scimType" => "uniqueness"}} = scim(other, :post, "/Users", ada())
  end

  test "groups give roles, and changes reconcile them", %{directory: directory, org_id: org_id} do
    {201, %{"id" => ada_id}} = scim(directory, :post, "/Users", ada())
    user = Authmk.Testing.get_user_by(Auth, email: "ada@acme.example")

    {201, group} =
      scim(directory, :post, "/Groups", %{
        "displayName" => "Admins",
        "members" => [%{"value" => ada_id}]
      })

    assert [%{"value" => ^ada_id}] = group["members"]
    assert role(org_id, user.id) == "admin"

    # Okta's way of removing one member.
    patch = %{"Operations" => [%{"op" => "remove", "path" => ~s(members[value eq "#{ada_id}"])}]}
    assert {200, %{"members" => []}} = scim(directory, :patch, "/Groups/" <> group["id"], patch)
    assert role(org_id, user.id) == "member"

    patch = %{
      "Operations" => [%{"op" => "add", "path" => "members", "value" => [%{"value" => ada_id}]}]
    }

    assert {200, _group} = scim(directory, :patch, "/Groups/" <> group["id"], patch)
    assert role(org_id, user.id) == "admin"

    assert {204, nil} = scim(directory, :delete, "/Groups/" <> group["id"])
    assert role(org_id, user.id) == "member"

    assert {400, %{"scimType" => "invalidValue"}} =
             scim(directory, :post, "/Groups", %{
               "displayName" => "X",
               "members" => [%{"value" => "not-a-member"}]
             })
  end

  test "replace and patch users in the ways directories do", %{directory: directory} do
    {201, %{"id" => id}} = scim(directory, :post, "/Users", ada())

    # PUT replaces the whole user.
    assert {200, %{"displayName" => "Ada King", "externalId" => "okta-2"}} =
             scim(
               directory,
               :put,
               "/Users/" <> id,
               ada(%{"displayName" => "Ada King", "externalId" => "okta-2"})
             )

    # No path: a value object, with a nested name and emails.
    patch = %{
      "Operations" => [
        %{
          "op" => "add",
          "value" => %{
            "name" => %{"familyName" => "King"},
            "emails" => [%{"value" => "ada.king@acme.example", "primary" => true}]
          }
        }
      ]
    }

    assert {200,
            %{
              "name" => %{"familyName" => "King"},
              "emails" => [%{"value" => "ada.king@acme.example"}]
            }} = scim(directory, :patch, "/Users/" <> id, patch)

    patch = %{
      "Operations" => [
        %{
          "op" => "replace",
          "path" => ~s(emails[type eq "work"].value),
          "value" => "ada@acme.example"
        },
        %{"op" => "remove", "path" => "externalId"}
      ]
    }

    assert {200, user} = scim(directory, :patch, "/Users/" <> id, patch)
    assert [%{"value" => "ada@acme.example"}] = user["emails"]
    refute Map.has_key?(user, "externalId")

    for {operations, type} <- [
          {[%{"op" => "replace", "path" => "password", "value" => "x"}], "invalidPath"},
          {[%{"op" => "remove", "path" => "userName"}], "mutability"},
          {[%{"op" => "move", "path" => "active"}], "invalidSyntax"},
          {[%{"op" => "replace"}], "noTarget"},
          {[%{"path" => "active"}], "invalidSyntax"}
        ] do
      assert {400, %{"scimType" => ^type}} =
               scim(directory, :patch, "/Users/" <> id, %{"Operations" => operations})
    end

    assert {400, %{"scimType" => "invalidSyntax"}} = scim(directory, :patch, "/Users/" <> id, %{})

    assert {400, %{"scimType" => "invalidValue"}} =
             scim(directory, :put, "/Users/" <> id, %{"userName" => "no email"})

    assert {404, _} = scim(directory, :put, "/Users/missing", ada())
    assert {404, _} = scim(directory, :patch, "/Users/missing", %{"Operations" => []})
  end

  test "filters, paging and discovery", %{directory: directory} do
    for n <- 1..3 do
      {201, _user} =
        scim(
          directory,
          :post,
          "/Users",
          ada(%{"userName" => "user#{n}@acme.example", "emails" => [], "externalId" => "x-#{n}"})
        )
    end

    assert {200, %{"totalResults" => 3, "itemsPerPage" => 2, "startIndex" => 2}} =
             scim(directory, :get, "/Users", %{startIndex: "2", count: "2"})

    for {filter, count} <- [
          {~s[(userName eq "user1@acme.example") or (externalId eq "x-2")], 2},
          {~s(externalId ne "x-1" and externalId pr), 2},
          {~s(userName ew "@ACME.example"), 3},
          {~s(externalId eq null), 0},
          {~s(active ne false), 3}
        ] do
      assert {200, %{"totalResults" => ^count}} =
               scim(directory, :get, "/Users", %{filter: filter})
    end

    for filter <- [
          ~s(userName gt "a"),
          ~s(userName eq "open),
          ~s[((((((userName pr))))))],
          ~s(userName eq "a" extra),
          ~s(userName co true),
          "#"
        ] do
      assert {400, %{"scimType" => "invalidFilter"}} =
               scim(directory, :get, "/Users", %{filter: filter})
    end

    assert {200, %{"totalResults" => 2}} = scim(Browser.new(Auth), :get, "/ResourceTypes")

    assert {200, %{"Resources" => [%{"name" => "User"}, %{"name" => "Group"}]}} =
             scim(Browser.new(Auth), :get, "/Schemas")
  end

  test "groups: replace, rename, empty, filter", %{directory: directory} do
    {201, %{"id" => ada_id}} = scim(directory, :post, "/Users", ada())

    {201, %{"id" => id}} =
      scim(directory, :post, "/Groups", %{"displayName" => "Engineers", "externalId" => "g-1"})

    assert {200, %{"members" => [_ada]}} =
             scim(directory, :put, "/Groups/" <> id, %{
               "displayName" => "Engineering",
               "members" => [%{"value" => ada_id}]
             })

    patch = %{
      "Operations" => [
        %{"op" => "replace", "value" => %{"displayName" => "Eng", "externalId" => "g-2"}},
        %{"op" => "remove", "path" => "members"}
      ]
    }

    assert {200, %{"displayName" => "Eng", "members" => []}} =
             scim(directory, :patch, "/Groups/" <> id, patch)

    assert {200, %{"totalResults" => 1}} =
             scim(directory, :get, "/Groups", %{filter: ~s(displayName eq "eng")})

    assert {200, %{"displayName" => "Eng"}} = scim(directory, :get, "/Groups/" <> id)

    assert {409, %{"scimType" => "uniqueness"}} =
             scim(directory, :post, "/Groups", %{"displayName" => "ENG"})

    assert {400, %{"scimType" => "invalidValue"}} = scim(directory, :post, "/Groups", %{})

    assert {400, %{"scimType" => "invalidPath"}} =
             scim(directory, :patch, "/Groups/" <> id, %{
               "Operations" => [%{"op" => "add", "path" => "owner", "value" => "x"}]
             })

    assert {404, _} = scim(directory, :get, "/Groups/missing")
    assert {404, _} = scim(directory, :delete, "/Groups/missing")
  end

  test "a connection sees only its own, and only with its token", %{
    directory: directory,
    admin: admin
  } do
    {201, %{"id" => id}} = scim(directory, :post, "/Users", ada())

    {_admin, conn} = post(admin, "/organization/create", %{name: "Other", slug: "other"})
    {:ok, other} = SCIM.create_connection(Auth, organization_id: json(conn)["id"])
    assert {404, _} = scim(directory(other.token), :get, "/Users/" <> id)
    assert {200, %{"totalResults" => 0}} = scim(directory(other.token), :get, "/Users")

    for token <- ["nope", "scim_" <> String.duplicate("a", 43)] do
      assert {401, %{"schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"]}} =
               scim(directory(token), :get, "/Users")
    end

    # Discovery is open.
    assert {200, %{"patch" => %{"supported" => true}}} =
             scim(Browser.new(Auth), :get, "/ServiceProviderConfig")
  end

  test "rotating and decommissioning connections", %{
    directory: directory,
    admin: admin,
    org_id: org_id
  } do
    {201, _user} = scim(directory, :post, "/Users", ada())
    {admin, conn} = get(admin, "/scim/connections", %{organization_id: org_id})
    [%{"id" => connection_id}] = json(conn)

    {admin, conn} = post(admin, "/scim/connections/rotate-token", %{connection_id: connection_id})
    rotated = directory(json(conn)["token"])
    assert {401, _} = scim(directory, :get, "/Users")
    assert {200, _list} = scim(rotated, :get, "/Users")

    {_admin, _conn} =
      post(admin, "/scim/connections/decommission", %{connection_id: connection_id})

    assert {401, _} = scim(rotated, :get, "/Users")
    user = Authmk.Testing.get_user_by(Auth, email: "ada@acme.example")
    assert_raise ArgumentError, fn -> Authmk.Testing.create_session(Auth, user) end

    # Only those allowed manage connections.
    {member, _user} = sign_up(Browser.new(Auth), %{email: "eve@acme.example"})
    {_member, conn} = post(member, "/scim/connections", %{organization_id: org_id})
    assert conn.status == 403
  end
end

defmodule Authmk.SCIMLinkingTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.SCIM
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        {Authmk.Plugins.SCIM,
         link_existing_users: true, on_delete: :delete, resolve_user: &__MODULE__.resolve/3}
      ]

    # The directory's employee number decides, when it's known.
    def resolve(%{external_id: "E-1"}, _connection, ctx),
      do: {:ok, Authmk.Store.get_by(ctx, :user, email: "boss@acme.example")}

    def resolve(_attrs, _connection, _ctx), do: :create
  end

  @moduletag auth: Auth

  defp directory do
    {:ok, connection} = SCIM.create_connection(Auth, organization_id: "acme")

    %{
      Browser.new(Auth)
      | origin: nil,
        headers: [{"authorization", "Bearer " <> connection.token}]
    }
  end

  defp scim(directory, method, path, body \\ %{}) do
    {_directory, conn} = Browser.request(directory, method, "/scim/v2" <> path, body)
    {conn.status, if(conn.resp_body == "", do: nil, else: json(conn))}
  end

  test "existing users are linked, the app resolves others, and deleting deletes" do
    directory = directory()
    ada = Authmk.Testing.create_user(Auth, email: "ada@acme.example")
    boss = Authmk.Testing.create_user(Auth, email: "boss@acme.example")

    assert {201, %{"id" => ada_id}} =
             scim(directory, :post, "/Users", %{"userName" => "ada@acme.example"})

    assert Authmk.Testing.get_user_by(Auth, email: "ada@acme.example").id == ada.id

    # A different email, but the employee number says it's the boss.
    assert {201, linked} =
             scim(directory, :post, "/Users", %{
               "userName" => "chief@acme.example",
               "externalId" => "E-1"
             })

    assert [%{"value" => email}] = linked["emails"]
    assert email == boss.email

    assert {204, nil} = scim(directory, :delete, "/Users/" <> ada_id)
    assert Authmk.Testing.get_user_by(Auth, email: "ada@acme.example") == nil
  end
end

defmodule Authmk.SCIMOrganizationLinkingTest do
  # With organizations, anyone may run one and connect a directory to it, so
  # linking existing users can't reach past the organization's own members.
  use Authmk.EmulationCase, async: true

  alias Authmk.Plugins.SCIM
  alias Authmk.Test.Browser

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [
        Authmk.Plugins.EmailPassword,
        Authmk.Plugins.Organization,
        {Authmk.Plugins.SCIM, link_existing_users: true}
      ]
  end

  @moduletag auth: Auth

  test "only the organization's own members are linked", %{browser: browser} do
    {owner, _user} = sign_up(browser, %{email: "owner@acme.example"})
    {_owner, conn} = post(owner, "/organization/create", %{name: "Acme", slug: "acme"})
    {:ok, connection} = SCIM.create_connection(Auth, organization_id: json(conn)["id"])

    {_victim, _user} = sign_up(Browser.new(Auth), %{email: "victim@example.com"})

    directory = %{
      Browser.new(Auth)
      | origin: nil,
        headers: [{"authorization", "Bearer " <> connection.token}]
    }

    {directory, conn} =
      Browser.request(directory, :post, "/scim/v2/Users", %{"userName" => "victim@example.com"})

    assert conn.status == 409
    assert json(conn)["scimType"] == "uniqueness"

    {_directory, conn} =
      Browser.request(directory, :post, "/scim/v2/Users", %{"userName" => "owner@acme.example"})

    assert conn.status == 201
  end
end
