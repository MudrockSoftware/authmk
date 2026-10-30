defmodule Authmk.Dashboard.API.Payments do
  @moduledoc false
  # Earnings and subscriptions (with a payment plugin). Plan changes,
  # cancels and resumes go through the provider (Authmk.Payments), and need
  # the Admin permission `subscription: update`.

  alias Authmk.Dashboard.{Data, Reply}
  alias Authmk.Dashboard.Data.Analytics
  alias Authmk.Dashboard.Data.Payments, as: Billing
  alias Authmk.Payments

  def route(conn, path, ctx, admin) do
    case Billing.setup(ctx) do
      nil -> Reply.not_found(conn)
      setup -> payments(conn, conn.method, path, ctx, admin, setup)
    end
  end

  defp payments(conn, "GET", [], ctx, _admin, setup) do
    case Analytics.range(Reply.param(conn, "from"), Reply.param(conn, "to")) do
      {:ok, first, last} ->
        Reply.json(conn, 200, Map.put(setup, :earnings, Billing.earnings(ctx, first, last)))

      {:error, message} ->
        Reply.error(conn, 400, "invalid_range", message)
    end
  end

  defp payments(conn, "GET", ["subscriptions"], ctx, _admin, _setup) do
    filters = [
      status: Reply.param(conn, "status"),
      plan: Reply.param(conn, "plan"),
      reference_type: Reply.param(conn, "reference_type")
    ]

    Reply.page(conn, Billing.list(ctx, filters, Reply.offset(conn)), :subscriptions)
  end

  defp payments(conn, "POST", ["subscriptions", id, action], ctx, admin, _setup)
       when action in ~w(cancel resume change-plan) do
    case Billing.find(ctx, id) do
      nil -> Reply.not_found(conn, "subscription")
      subscription -> act(conn, ctx, admin, subscription, action)
    end
  end

  defp payments(conn, _method, _path, _ctx, _admin, _setup), do: Reply.not_found(conn)

  defp act(conn, ctx, admin, subscription, "cancel") do
    immediately = Reply.param(conn, "immediately") == true
    event = event(subscription, "subscription.canceled", immediately: immediately)

    change(conn, ctx, admin, event, fn auth ->
      Payments.cancel(auth, subscription.id, immediately: immediately)
    end)
  end

  defp act(conn, ctx, admin, subscription, "resume") do
    change(conn, ctx, admin, event(subscription, "subscription.resumed"), fn auth ->
      Payments.resume(auth, subscription.id)
    end)
  end

  defp act(conn, ctx, admin, subscription, "change-plan") do
    plan = Reply.param(conn, "plan")
    annual = Reply.param(conn, "annual") == true

    event =
      event(subscription, "subscription.plan_changed",
        from: subscription.plan,
        to: plan,
        annual: annual
      )

    change(conn, ctx, admin, event, fn auth ->
      Payments.change_plan(auth, subscription.id, plan || "", annual: annual)
    end)
  end

  defp change(conn, ctx, admin, event, fun) do
    Reply.permitted(conn, ctx, admin, %{subscription: [:update]}, event, fn ->
      with {:ok, subscription} <- fun.(ctx.config.auth),
           do: {:ok, %{subscription: Data.subscription(subscription)}}
    end)
  end

  defp event(subscription, name, metadata \\ []) do
    details = %{
      metadata:
        Map.new(metadata)
        |> Map.merge(%{
          subscription_id: to_string(subscription.id),
          reference_type: subscription.reference_type,
          reference_id: subscription.reference_id
        })
    }

    details =
      case subscription.reference_type do
        "user" -> Map.put(details, :user_id, subscription.reference_id)
        "organization" -> Map.put(details, :organization_id, subscription.reference_id)
      end

    {name, details}
  end
end
