defmodule Authmk.Payments.Reference do
  @moduledoc false
  # Who's billed: the signed-in user, or (with `organizations: true`) an
  # organization they may manage billing for: its owners and admins, or
  # whoever the app's `authorize_reference` allows.
  #
  # A reference is its type and id together: with integer ids, user 1 and
  # organization 1 are different customers, so nothing looks one up by id
  # alone.

  alias Authmk.{AccessControl, Context, Error, Store}

  @managers ["owner", "admin"]

  @doc "The app's way of naming one (`user_id` or `{:organization, id}`), as `%{type:, id:}`."
  def from_app({:organization, id}), do: %{type: "organization", id: to_string(id)}
  def from_app(user_id), do: %{type: "user", id: to_string(user_id)}

  @doc """
  The id a provider that keeps our ids (`external_id`) knows a reference
  by: `user_<id>` or `org_<id>`, so the two can't collide there either.
  """
  def external_id(%{type: "user", id: id}), do: "user_" <> id
  def external_id(%{type: "organization", id: id}), do: "org_" <> id

  # `reference_id` in a request names an organization; without it, the
  # signed-in user is billed.
  def resolve(%Context{user: user} = ctx, reference_id, action, opts) do
    cond do
      reference_id in [nil, ""] ->
        {:ok, %{id: to_string(user.id), type: "user", email: user.email, name: user.name}}

      not opts[:organizations] or not Map.has_key?(ctx.config.schema.models, :member) ->
        {:error, forbidden()}

      allowed?(ctx, user, reference_id, action, opts) ->
        organization(ctx, reference_id, user)

      true ->
        {:error, forbidden()}
    end
  end

  defp allowed?(ctx, user, reference_id, action, opts) do
    case opts[:authorize_reference] do
      nil -> manager?(ctx, user, reference_id)
      authorize -> authorize.(user, reference_id, action, ctx) == true
    end
  end

  defp manager?(ctx, user, organization_id) do
    case Store.get_by(ctx, :member, organization_id: organization_id, user_id: user.id) do
      %{role: role} -> Enum.any?(AccessControl.parse_roles(role), &(&1 in @managers))
      nil -> false
    end
  rescue
    Ecto.Query.CastError -> false
  end

  # Billed to the organization, with the manager's email for the provider.
  defp organization(ctx, id, user) do
    case Store.get_by(ctx, :organization, id: id) do
      nil ->
        {:error, forbidden()}

      org ->
        {:ok, %{id: to_string(org.id), type: "organization", email: user.email, name: org.name}}
    end
  rescue
    Ecto.Query.CastError -> {:error, forbidden()}
  end

  defp forbidden, do: Error.new(:forbidden)
end
