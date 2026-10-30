defmodule Authmk.Plugins.SSO.SAML.Replay do
  @moduledoc false
  # Each assertion signs in once: its issuer and ID are recorded until it
  # expires, under a unique key, so of two requests racing with the same
  # assertion only one can insert it. Expired records are cleared as new
  # ones come.

  import Ecto.Query, only: [dynamic: 2]

  alias Authmk.Store

  @doc "`:ok` the first time an assertion is seen, `{:error, :replayed}` after."
  def record(ctx, issuer, assertion_id, expires_at) do
    now = DateTime.utc_now()
    _cleared = Store.delete_all(ctx, :saml_assertion, dynamic([a], a.expires_at <= ^now))
    key = :sha256 |> :crypto.hash([issuer, 0, assertion_id]) |> Base.encode16(case: :lower)

    case Store.insert(ctx, :saml_assertion, %{key: key, expires_at: expires_at}) do
      {:ok, _record} -> :ok
      {:error, _taken} -> {:error, :replayed}
    end
  end
end
