defmodule Authmk.Plugins.Organization.Invitations do
  @moduledoc false
  # Invitation endpoints: invite, cancel, accept, reject, get and list.

  import Ecto.Query, only: [from: 2]

  alias Authmk.{AccessControl, Background, Context, Email, Error, Serializer, Store}
  alias Authmk.Plugins.Organization.{Access, Config, Errors, Hooks, Members, Organizations}

  def invite(%Context{params: params, user: inviter} = ctx) do
    opts = Config.opts(ctx)
    email = Email.normalize(params.email)
    role = params.role |> AccessControl.parse_roles() |> Enum.join(",")

    with :ok <- sender(opts),
         :ok <- check(Email.valid?(email), Error.new(:invalid_email)),
         {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, actor} <- Access.authorize(ctx, id, invitation: [:create]),
         :ok <- check(Access.valid_role?(ctx, organization, role), Errors.error(:invalid_role)),
         :ok <- Access.check_owner_change(ctx, actor, role),
         :ok <- not_a_member(ctx, organization, email),
         :ok <- valid_team(ctx, organization, params.team_id),
         {:ok, previous} <- previous_invitation(ctx, organization, email, params.resend, opts),
         :ok <- under_limit(ctx, organization, opts),
         {:ok, invitation} <-
           write(ctx, previous, invitation_attrs(ctx, organization, email, role, opts)) do
      Background.plugin_callback(ctx, Config.plugin(ctx), :send_invitation_email, %{
        id: invitation.id,
        email: email,
        role: role,
        organization: organization,
        inviter: inviter
      })

      {:ok, Serializer.record(ctx, :invitation, invitation), ctx}
    end
  end

  def cancel(%Context{params: params} = ctx) do
    with {:ok, invitation} <- pending(ctx, params.invitation_id),
         {:ok, _organization, _member} <-
           Access.authorize(ctx, invitation.organization_id, invitation: [:cancel]),
         {:ok, invitation} <- set_status(ctx, invitation, "canceled", :cancel_invitation) do
      {:ok, Serializer.record(ctx, :invitation, invitation), ctx}
    end
  end

  # The invitee joins with the invitation's role (and team), and the
  # organization becomes active.
  def accept(%Context{params: params, user: user} = ctx) do
    with {:ok, invitation} <- own_pending(ctx, params.invitation_id),
         {:ok, organization} <- Access.fetch_organization(ctx, invitation.organization_id),
         :ok <- under_organization_limit(ctx, user),
         {:ok, member} <- join(ctx, organization, user, invitation),
         {:ok, invitation} <- set_status(ctx, invitation, "accepted", :accept_invitation),
         {:ok, ctx} <- Organizations.activate(ctx, organization) do
      {:ok,
       %{
         invitation: Serializer.record(ctx, :invitation, invitation),
         member: Serializer.record(ctx, :member, member)
       }, ctx}
    end
  end

  def reject(%Context{params: params} = ctx) do
    with {:ok, invitation} <- own_pending(ctx, params.invitation_id),
         {:ok, invitation} <- set_status(ctx, invitation, "rejected", :reject_invitation) do
      {:ok, %{invitation: Serializer.record(ctx, :invitation, invitation)}, ctx}
    end
  end

  # The invitee sees their own invitation, with the organization's name.
  def get(%Context{params: params} = ctx) do
    with {:ok, invitation} <- own_pending(ctx, params.id),
         {:ok, organization} <- Access.fetch_organization(ctx, invitation.organization_id) do
      body =
        ctx
        |> Serializer.record(:invitation, invitation)
        |> Map.merge(%{
          organization_name: organization.name,
          organization_slug: organization.slug
        })

      {:ok, body, ctx}
    end
  end

  def list(%Context{params: params} = ctx) do
    with {:ok, id} <- Access.organization_id(ctx, params.organization_id),
         {:ok, organization, _member} <- Access.member_of(ctx, id) do
      invitations = Store.all(ctx, :invitation, organization_id: organization.id)
      {:ok, Enum.map(invitations, &Serializer.record(ctx, :invitation, &1)), ctx}
    end
  end

  def list_for_user(%Context{user: user} = ctx) do
    invitation = Store.module(ctx, :invitation)
    now = DateTime.utc_now()

    query =
      from(i in invitation,
        where: i.email == ^user.email and i.status == "pending" and i.expires_at > ^now,
        order_by: [desc: i.inserted_at]
      )

    {:ok,
     ctx |> Store.list(:invitation, query) |> Enum.map(&Serializer.record(ctx, :invitation, &1)),
     ctx}
  end

  defp join(ctx, organization, user, invitation) do
    Store.transaction(ctx, fn ->
      with {:ok, member} <- Members.add(ctx, organization, user, invitation.role),
           :ok <- join_team(ctx, Map.get(invitation, :team_id), user) do
        {:ok, member}
      end
    end)
  end

  defp join_team(_ctx, nil, _user), do: :ok

  defp join_team(ctx, team_id, user) do
    with {:ok, _team_member} <-
           Store.insert(ctx, :team_member, %{team_id: team_id, user_id: user.id}),
         do: :ok
  end

  # A pending, unexpired invitation for the signed-in user's own email.
  defp own_pending(%Context{user: user} = ctx, id) do
    opts = Config.opts(ctx)

    with {:ok, invitation} <- pending(ctx, id),
         :ok <- check(invitation.email == user.email, Errors.error(:invitation_not_found)),
         :ok <- verified(user, opts) do
      {:ok, invitation}
    end
  end

  defp pending(ctx, id) do
    case safe_get(ctx, id) do
      %{status: "pending"} = invitation ->
        if DateTime.after?(invitation.expires_at, DateTime.utc_now()),
          do: {:ok, invitation},
          else: {:error, Errors.error(:invitation_expired)}

      _missing_or_done ->
        {:error, Errors.error(:invitation_not_found)}
    end
  end

  defp safe_get(ctx, id) do
    Store.get_by(ctx, :invitation, id: id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp verified(user, opts) do
    if opts[:require_email_verification_on_invitation] and not user.email_verified,
      do: {:error, Errors.error(:email_not_verified)},
      else: :ok
  end

  defp set_status(ctx, invitation, status, event) do
    with {:ok, attrs} <- Hooks.before_event(ctx, event, %{status: status}),
         {:ok, invitation} <- Store.update(ctx, :invitation, invitation, attrs) do
      :ok = Hooks.after_event(ctx, event, invitation)
      {:ok, invitation}
    end
  end

  # A pending invitation for the same email: resent, replaced, or a conflict.
  defp previous_invitation(ctx, organization, email, resend, opts) do
    case pending_for(ctx, organization, email) do
      nil -> {:ok, nil}
      invitation when resend -> {:ok, invitation}
      invitation -> replace_or_refuse(ctx, invitation, opts)
    end
  end

  defp replace_or_refuse(ctx, invitation, opts) do
    if opts[:cancel_pending_invitations_on_re_invite] do
      with {:ok, _canceled} <- set_status(ctx, invitation, "canceled", :cancel_invitation),
           do: {:ok, nil}
    else
      {:error, Errors.error(:already_invited)}
    end
  end

  defp pending_for(ctx, organization, email) do
    now = DateTime.utc_now()
    invitation = Store.module(ctx, :invitation)

    query =
      from(i in invitation,
        where:
          i.organization_id == ^organization.id and i.email == ^email and i.status == "pending" and
            i.expires_at > ^now,
        limit: 1
      )

    ctx |> Store.list(:invitation, query) |> List.first()
  end

  # Resending refreshes the expiry of the invitation that's there.
  defp write(ctx, nil, attrs) do
    with {:ok, attrs} <- Hooks.before_event(ctx, :create_invitation, attrs),
         {:ok, invitation} <- Store.insert(ctx, :invitation, attrs) do
      :ok = Hooks.after_event(ctx, :create_invitation, invitation)
      {:ok, invitation}
    end
  end

  defp write(ctx, previous, attrs),
    do: Store.update(ctx, :invitation, previous, Map.take(attrs, [:role, :expires_at, :team_id]))

  defp invitation_attrs(%Context{user: inviter, params: params}, organization, email, role, opts) do
    %{
      organization_id: organization.id,
      email: email,
      role: role,
      status: "pending",
      inviter_id: inviter.id,
      team_id: params.team_id,
      expires_at: DateTime.add(DateTime.utc_now(), opts[:invitation_expires_in])
    }
  end

  defp not_a_member(ctx, organization, email) do
    with %{} = user <- Store.get_by(ctx, :user, email: email),
         %{} <- Store.get_by(ctx, :member, organization_id: organization.id, user_id: user.id) do
      {:error, Errors.error(:already_member)}
    else
      nil -> :ok
    end
  end

  defp valid_team(_ctx, _organization, nil), do: :ok

  defp valid_team(ctx, organization, team_id) do
    team = Config.opts(ctx)[:teams][:enabled] && safe_team(ctx, team_id)

    if team && team.organization_id == organization.id,
      do: :ok,
      else: {:error, Errors.error(:team_not_found)}
  end

  defp safe_team(ctx, id) do
    Store.get_by(ctx, :team, id: id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp under_limit(ctx, organization, opts) do
    now = DateTime.utc_now()
    invitation = Store.module(ctx, :invitation)

    query =
      from(i in invitation,
        where:
          i.organization_id == ^organization.id and i.status == "pending" and i.expires_at > ^now
      )

    check(
      Store.count(ctx, :invitation, query) < opts[:invitation_limit],
      Errors.error(:invitation_limit_reached)
    )
  end

  defp under_organization_limit(ctx, user) do
    case Config.opts(ctx)[:organization_limit] do
      nil ->
        :ok

      limit ->
        count =
          Store.count(
            ctx,
            :member,
            from(m in Store.module(ctx, :member), where: m.user_id == ^user.id)
          )

        check(count < limit, Errors.error(:organization_limit_reached))
    end
  end

  defp sender(opts) do
    if opts[:send_invitation_email], do: :ok, else: {:error, Error.new(:feature_disabled)}
  end

  defp check(true, _error), do: :ok
  defp check(_false, error), do: {:error, error}
end
