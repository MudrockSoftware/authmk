defmodule Authmk.Plugins.Gate.Page do
  @moduledoc false
  # Which resource a page is about, for Authmk.Plug.RequireAbility and the
  # `:require_ability` LiveView hook, from their `resource:` option:
  #
  #   * `nil`: the app, no organization;
  #   * `{:param, :organization, "org_id"}` or `{:param, :team, "team_id"}`:
  #     the id in that path param (a LiveView's params);
  #   * `:active_organization`: the session's active organization, for
  #     pages that show only its data.

  @doc "Raises for options these pages can't use."
  def validate!(nil), do: nil
  def validate!(:active_organization), do: :active_organization

  def validate!({:param, kind, name} = spec)
      when kind in [:organization, :team] and is_binary(name),
      do: spec

  def validate!(other) do
    raise ArgumentError,
          "resource: takes nil, :active_organization, {:param, :organization, name} " <>
            "or {:param, :team, name}, got: #{inspect(other)}"
  end

  @doc "The resource for a Gate check."
  def resource(nil, _params, _session), do: nil

  def resource(:active_organization, _params, session),
    do: {:organization, session && Map.get(session, :active_organization_id)}

  def resource({:param, kind, name}, params, _session), do: {kind, Map.get(params, name)}
end
