defmodule Authmk.Plugins.SCIM.API do
  @moduledoc false
  # The SCIM endpoints' handlers: each authenticates the connection by its
  # bearer token first, answering in SCIM's error format when it can't.

  alias Authmk.{Context, Store}
  alias Authmk.Plugins.SCIM.{Connections, Errors, Groups, Users}

  def list_users(ctx), do: authenticated(ctx, &Users.list/1)
  def create_user(ctx), do: authenticated(ctx, &Users.create/1)
  def get_user(ctx), do: authenticated(ctx, &Users.get/1)
  def replace_user(ctx), do: authenticated(ctx, &Users.replace/1)
  def patch_user(ctx), do: authenticated(ctx, &Users.patch/1)
  def delete_user(ctx), do: authenticated(ctx, &Users.delete/1)
  def list_groups(ctx), do: authenticated(ctx, &Groups.list/1)
  def create_group(ctx), do: authenticated(ctx, &Groups.create/1)
  def get_group(ctx), do: authenticated(ctx, &Groups.get/1)
  def replace_group(ctx), do: authenticated(ctx, &Groups.replace/1)
  def patch_group(ctx), do: authenticated(ctx, &Groups.patch/1)
  def delete_group(ctx), do: authenticated(ctx, &Groups.delete/1)

  defp authenticated(ctx, handler) do
    case Connections.authenticate(ctx) do
      {:ok, connection} ->
        _seen =
          Store.update(ctx, :scim_connection, connection, %{last_used_at: DateTime.utc_now()})

        handler.(Context.put_private(ctx, :scim_connection, connection))

      :error ->
        ctx
        |> Context.put_resp_header("www-authenticate", ~s(Bearer realm="scim"))
        |> Errors.unauthorized()
    end
  end

  @doc "GET /scim/v2/ServiceProviderConfig"
  def service_provider_config(ctx) do
    Errors.json(ctx, 200, %{
      schemas: ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
      patch: %{supported: true},
      bulk: %{supported: false, maxOperations: 0, maxPayloadSize: 0},
      filter: %{supported: true, maxResults: 100},
      changePassword: %{supported: false},
      sort: %{supported: false},
      etag: %{supported: false},
      authenticationSchemes: [
        %{
          type: "oauthbearertoken",
          name: "Bearer token",
          description: "The connection's token",
          primary: true
        }
      ]
    })
  end

  @doc "GET /scim/v2/ResourceTypes"
  def resource_types(ctx) do
    types = [
      %{
        schemas: ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
        id: "User",
        name: "User",
        endpoint: "/Users",
        schema: "urn:ietf:params:scim:schemas:core:2.0:User"
      },
      %{
        schemas: ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
        id: "Group",
        name: "Group",
        endpoint: "/Groups",
        schema: "urn:ietf:params:scim:schemas:core:2.0:Group"
      }
    ]

    Errors.json(ctx, 200, %{
      schemas: ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
      totalResults: 2,
      Resources: types
    })
  end

  @doc "GET /scim/v2/Schemas: the attributes this server keeps."
  def schemas(ctx) do
    attribute = fn name, type ->
      %{
        name: name,
        type: type,
        multiValued: false,
        required: false,
        mutability: "readWrite",
        returned: "default"
      }
    end

    schemas = [
      %{
        id: "urn:ietf:params:scim:schemas:core:2.0:User",
        name: "User",
        attributes: [
          %{attribute.("userName", "string") | required: true},
          attribute.("displayName", "string"),
          attribute.("active", "boolean"),
          attribute.("externalId", "string"),
          %{
            name: "name",
            type: "complex",
            multiValued: false,
            subAttributes: [
              attribute.("givenName", "string"),
              attribute.("familyName", "string"),
              attribute.("formatted", "string")
            ]
          },
          %{
            name: "emails",
            type: "complex",
            multiValued: true,
            subAttributes: [attribute.("value", "string"), attribute.("primary", "boolean")]
          }
        ]
      },
      %{
        id: "urn:ietf:params:scim:schemas:core:2.0:Group",
        name: "Group",
        attributes: [
          %{attribute.("displayName", "string") | required: true},
          attribute.("externalId", "string"),
          %{
            name: "members",
            type: "complex",
            multiValued: true,
            subAttributes: [attribute.("value", "string")]
          }
        ]
      }
    ]

    Errors.json(ctx, 200, %{
      schemas: ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
      totalResults: length(schemas),
      Resources: schemas
    })
  end
end
