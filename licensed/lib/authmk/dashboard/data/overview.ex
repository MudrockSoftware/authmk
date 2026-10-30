defmodule Authmk.Dashboard.Data.Overview do
  @moduledoc false
  # The home page: totals, the last 30 days of sign-ups and sign-ins, how
  # people sign in, and the newest users.

  import Ecto.Query

  alias Authmk.Dashboard.Data
  alias Authmk.Dashboard.Data.Analytics
  alias Authmk.Store

  def get(ctx) do
    %{
      totals: totals(ctx),
      sign_ups: Analytics.sign_ups_per_day(ctx, 30),
      sign_ins: Analytics.sign_ins_per_day(ctx, 30),
      sign_in_methods: sign_in_methods(ctx),
      recent_users:
        Store.list(
          ctx,
          :user,
          from(u in Store.module(ctx, :user),
            order_by: [desc: u.inserted_at, desc: u.id],
            limit: 5
          )
        )
        |> Enum.map(&Data.user/1)
    }
  end

  defp totals(ctx) do
    users = from(u in Store.module(ctx, :user))
    now = DateTime.utc_now()

    %{
      users: Store.count(ctx, :user, users),
      verified_users: Store.count(ctx, :user, where(users, [u], u.email_verified == true)),
      two_factor_users:
        if(Data.field?(ctx, :user, :two_factor_enabled),
          do: Store.count(ctx, :user, where(users, [u], u.two_factor_enabled == true))
        ),
      organizations: count(ctx, :organization),
      active_sessions:
        Store.count(
          ctx,
          :session,
          from(s in Store.module(ctx, :session), where: s.expires_at > ^now)
        ),
      # Programs, counted apart from people.
      service_accounts: count(ctx, :service_account),
      active_service_accounts:
        if(Data.model?(ctx, :service_account),
          do:
            Store.count(
              ctx,
              :service_account,
              from(s in Store.module(ctx, :service_account),
                where: s.last_used_at > ^DateTime.add(now, -30 * 86_400)
              )
            )
        )
    }
  end

  defp count(ctx, model) do
    if Data.model?(ctx, model), do: Store.count(ctx, model, from(r in Store.module(ctx, model)))
  end

  # The linked accounts: how people can sign in.
  defp sign_in_methods(ctx) do
    query =
      from(a in Store.module(ctx, :account),
        group_by: a.provider_id,
        select: {a.provider_id, count(a.id)},
        order_by: [desc: count(a.id)],
        limit: 12
      )

    for {provider, count} <- Store.list(ctx, :account, query),
        do: %{provider: provider, count: count}
  end
end
