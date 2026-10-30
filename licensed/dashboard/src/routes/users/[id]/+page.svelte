<script lang="ts">
  import { page } from "$app/state";
  import Avatar from "#lib/components/Avatar.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import OutcomeAlert from "#lib/components/OutcomeAlert.svelte";
  import SubscriptionsCard from "#lib/components/SubscriptionsCard.svelte";
  import AccessCard from "#lib/components/user/AccessCard.svelte";
  import AccountsCard from "#lib/components/user/AccountsCard.svelte";
  import ActivityCard from "#lib/components/user/ActivityCard.svelte";
  import ApiKeysCard from "#lib/components/user/ApiKeysCard.svelte";
  import ProfileCard from "#lib/components/user/ProfileCard.svelte";
  import SecondFactorsCard from "#lib/components/user/SecondFactorsCard.svelte";
  import SessionsCard from "#lib/components/user/SessionsCard.svelte";
  import UserActions from "#lib/components/user/UserActions.svelte";
  import { api, type UserDetail } from "#lib/api.ts";
  import { formatDateTime } from "#lib/format.ts";
  import { Outcome } from "#lib/outcome.svelte.ts";
  import { session } from "#lib/session.svelte.ts";

  const id = $derived(page.params.id ?? "");
  const features = $derived(session.me!.features);

  let detail = $state<UserDetail | null>(null);
  let failure = $state<unknown>(null);
  const outcome = new Outcome(load);

  async function load() {
    try {
      detail = await api.user(id);
      failure = null;
    } catch (error) {
      failure = error;
    }
  }

  $effect(() => {
    void id;
    outcome.notice = null;
    load();
  });

  const showFactors = $derived(
    !!detail && (features.two_factor || features.passkeys || detail.two_factor.phone_number !== null)
  );
</script>

<a href="#/users" class="link link-hover text-base-content/70 text-sm">← Users</a>

{#if failure}<div class="mt-4"><Failure error={failure} /></div>{/if}

{#if detail}
  {@const user = detail.user}
  <section class="card border-base-300 bg-base-100 mt-4 border">
    <div class="card-body flex-row flex-wrap items-center gap-4">
      <Avatar name={user.name} email={user.email} size="size-14" />
      <div class="min-w-0 flex-1">
        <h1 class="text-2xl font-semibold">{user.name ?? user.email}</h1>
        <div class="text-base-content/70 text-sm">{user.email} · joined {formatDateTime(user.created_at)}</div>
        <div class="mt-2 flex flex-wrap gap-1">
          {#if user.banned}
            <span class="badge badge-error">
              Banned{user.ban_reason ? `: ${user.ban_reason}` : ""}{user.ban_expires ? ` (until ${formatDateTime(user.ban_expires)})` : ""}
            </span>
          {/if}
          {#if user.role}<span class="badge badge-primary badge-soft">{user.role}</span>{/if}
          <span class="badge {user.email_verified ? 'badge-success' : 'badge-ghost'} badge-soft">{user.email_verified ? "Email verified" : "Email not verified"}</span>
          {#if user.two_factor_enabled !== null}
            <span class="badge {user.two_factor_enabled ? 'badge-secondary' : 'badge-ghost'} badge-soft">Two-factor {user.two_factor_enabled ? "on" : "off"}</span>
          {/if}
        </div>
      </div>
      <UserActions {detail} {outcome} />
    </div>
  </section>

  <OutcomeAlert {outcome} />

  <div class="mt-6 grid gap-6 xl:grid-cols-3">
    <div class="flex flex-col gap-6 xl:col-span-2">
      {#key detail}<ProfileCard {detail} {outcome} />{/key}
      <AccessCard access={detail.access} />
      <SessionsCard userId={user.id} sessions={detail.sessions} {outcome} />
    </div>

    <div class="flex flex-col gap-6">
      <AccountsCard userId={user.id} accounts={detail.accounts} {outcome} />
      {#if showFactors}<SecondFactorsCard userId={user.id} factors={detail.two_factor} {outcome} />{/if}
    </div>
  </div>

  {#if features.api_keys}<div class="mt-6"><ApiKeysCard keys={detail.api_keys} /></div>{/if}
  {#if features.payments}<div class="mt-6"><SubscriptionsCard subscriptions={detail.subscriptions} /></div>{/if}
  {#if features.audit_log}<div class="mt-6"><ActivityCard events={detail.events} userId={user.id} /></div>{/if}
{:else if !failure}
  <Loading />
{/if}
