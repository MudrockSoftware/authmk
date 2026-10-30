defmodule Authmk.Payments.Reference do
  @moduledoc false
  # Who's billed: the signed-in user, or (with `organizations: true`) an
  # organization they may manage billing for: its owners and admins, or
  # whoever the app's `authorize_reference` allows.

  alias Authmk.{AccessControl, Context, Error, Store}

  @managers ["owner", "admin"]

  def resolve(%Context{user: user} = ctx, reference_id, action, opts) do
    cond do
      reference_id in [nil, "", to_string(user.id)] ->
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
