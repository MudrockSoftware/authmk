defmodule Authmk.Plugins.Gate.Scope do
  @moduledoc false
  # Where a resource lives: in no organization (`:app`), or in an
  # organization and maybe one of its teams. Always from the resource
  # itself, never from the session's active organization, so a member of
  # one organization can't reach another's data by switching.

  alias Authmk.{Context, Store}

  @type t :: :app | {:organization, term(), term() | nil} | :nowhere

  @doc """
  The scope of `resource`:

    * `nil`: the app, with no organization;
    * `{:organization, id}` or `{:team, id}`;
    * an organization or team record;
    * any other map or struct with an `organization_id` or `team_id` key.
      `nil` in both means it belongs to no organization.

  `:nowhere` when the resource names a team that doesn't exist, or a team
  in another organization than the one it names: nothing in an
  organization grants access to it then.
  """
  @spec of(Context.t(), term()) :: t()
  def of(_ctx, nil), do: :app
  def of(_ctx, {:organization, nil}), do: :nowhere
  def of(_ctx, {:organization, id}), do: {:organization, id, nil}
  def of(ctx, {:team, id}), do: team(ctx, id, nil)

  def of(ctx, %{__struct__: struct} = record) when is_atom(struct) do
    cond do
      model?(ctx, :organization, struct) -> {:organization, record.id, nil}
      model?(ctx, :team, struct) -> team(ctx, record.id, record.organization_id)
      true -> record(ctx, Map.from_struct(record))
    end
  end

  def of(ctx, resource) when is_map(resource), do: record(ctx, resource)

  def of(_ctx, resource) do
    raise ArgumentError,
          "can't tell which organization #{inspect(resource)} belongs to; " <>
            "pass a map with organization_id or team_id, {:organization, id} or {:team, id}"
  end

  defp record(ctx, resource) do
    unless Map.has_key?(resource, :organization_id) or Map.has_key?(resource, :team_id) do
      raise ArgumentError,
            "can't tell which organization the resource belongs to: it has no " <>
              "organization_id or team_id key (keys: #{inspect(Map.keys(resource))})"
    end

    organization_id = Map.get(resource, :organization_id)
    team_id = Map.get(resource, :team_id)

    cond do
      team_id != nil and teams?(ctx) -> team(ctx, team_id, organization_id)
      organization_id != nil -> {:organization, organization_id, nil}
      # Owned by a team, but the app has no authmk teams to check.
      team_id != nil -> :nowhere
      true -> :app
    end
  end

  # The team's own organization; it must match the one the resource names.
  defp team(ctx, team_id, organization_id) do
    with true <- teams?(ctx),
         %{} = team <- fetch_team(ctx, team_id),
         true <- organization_id == nil or same_id?(organization_id, team.organization_id) do
      {:organization, team.organization_id, team.id}
    else
      _missing -> :nowhere
    end
  end

  defp fetch_team(_ctx, nil), do: nil

  defp fetch_team(ctx, id) do
    Store.get_by(ctx, :team, id: id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp same_id?(a, b), do: to_string(a) == to_string(b)

  defp teams?(ctx), do: Map.has_key?(ctx.config.schema.models, :team)

  defp model?(ctx, key, struct) do
    case ctx.config.schema.models do
      %{^key => %{module: ^struct}} -> true
      _other -> false
    end
  end
end
