defmodule Authmk.Plugins.SCIM.Errors do
  @moduledoc false
  # SCIM's error format (RFC 7644 3.12) and content type.

  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  @doc "A SCIM JSON answer."
  def json(ctx, status, body) do
    {:json, status, body,
     Authmk.Context.put_resp_header(ctx, "content-type", "application/scim+json")}
  end

  @doc "A SCIM error. `scim_type` is one of RFC 7644's (`invalidFilter`, `uniqueness`...)."
  def error(ctx, status, scim_type, detail) do
    body =
      %{schemas: [@error_schema], status: to_string(status), scimType: scim_type, detail: detail}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    json(ctx, status, body)
  end

  def not_found(ctx), do: error(ctx, 404, nil, "Resource not found")

  def unauthorized(ctx),
    do: error(ctx, 401, nil, "A valid bearer token for a SCIM connection is required")
end
