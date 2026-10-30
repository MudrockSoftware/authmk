<script lang="ts">
  import BadgeCheck from "@lucide/svelte/icons/badge-check";
  import LogIn from "@lucide/svelte/icons/log-in";
  import ShieldAlert from "@lucide/svelte/icons/shield-alert";
  import UserPlus from "@lucide/svelte/icons/user-plus";
  import Download from "@lucide/svelte/icons/download";
  import Fingerprint from "@lucide/svelte/icons/fingerprint";
  import Info from "@lucide/svelte/icons/info";
  import ShieldCheck from "@lucide/svelte/icons/shield-check";
  import Smartphone from "@lucide/svelte/icons/smartphone";
  import Breakdown from "#lib/components/Breakdown.svelte";
  import Card from "#lib/components/Card.svelte";
  import Chart from "#lib/components/Chart.svelte";
  import DateRange from "#lib/components/DateRange.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import OrganizationSelect from "#lib/components/OrganizationSelect.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import StatCard from "#lib/components/StatCard.svelte";
  import { api, exportUrl, type Analytics, type Range } from "#lib/api.ts";
  import { count, daysAgo, isoDay, percent, shortDay } from "#lib/format.ts";
  import { session } from "#lib/session.svelte.ts";

  const me = $derived(session.me!);

  let range = $state<Range>({ from: daysAgo(29), to: isoDay(new Date()) });
  let organizationId = $state("");
  let report = $state<Analytics | null>(null);
  let loading = $state(true);
  let failure = $state<unknown>(null);

  // Only the latest answer counts, if the filters changed meanwhile.
  let latest = 0;

  async function load(asked: Range, organization: string) {
    const mine = ++latest;
    loading = true;
    failure = null;
    try {
      const data = await api.analytics(asked, organization || undefined);
      if (mine === latest) report = data;
    } catch (error) {
      if (mine === latest) failure = error;
    } finally {
      if (mine === latest) loading = false;
    }
  }

  $effect(() => {
    load(range, organizationId);
  });

  const total = (days: { count: number }[]) => days.reduce((sum, day) => sum + day.count, 0);
  const labels = $derived(report ? report.sign_ups.map((d) => shortDay(d.day)) : []);
  const auditLogNote = "Needs the audit log: add Authmk.Plugins.AuditLog to keep sign-ins after sessions end.";
</script>

<PageHeader title="Analytics" description="Who signs in and how, day by day (UTC).">
  {#snippet actions()}
    <a class="btn btn-sm" href={exportUrl("analytics", { ...range, organization_id: organizationId })} download>
      <Download class="size-4" aria-hidden="true" /> Export daily CSV
    </a>
  {/snippet}
</PageHeader>

<div class="mb-6 flex flex-wrap items-end gap-2">
  <DateRange bind:range />
  {#if me.features.organizations}<OrganizationSelect bind:value={organizationId} size="select-sm" />{/if}
</div>

{#if failure}<Failure error={failure} />{/if}

{#if report}
  {@const r = report}
  <div class="flex flex-col gap-6 {loading ? 'opacity-60' : ''}" aria-busy={loading}>
    {#if r.source === "sessions"}
      <div role="note" class="alert alert-info alert-soft text-sm">
        <Info class="size-5" aria-hidden="true" />
        <span>
          Sign-ins are counted from the sessions still stored, so older days look quieter than they were. Add the audit log plugin
          (<code class="font-mono">Authmk.Plugins.AuditLog</code>) for full history, sign-in methods and failed sign-ins.
        </span>
      </div>
    {/if}

    <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      <StatCard title="Sign-ins" value={total(r.sign_ins).toLocaleString("en-GB")} icon={LogIn} />
      <StatCard title="Sign-ups" value={total(r.sign_ups).toLocaleString("en-GB")} icon={UserPlus} />
      {#if r.failed_sign_ins}<StatCard title="Failed sign-ins" value={total(r.failed_sign_ins).toLocaleString("en-GB")} icon={ShieldAlert} />{/if}
    </div>

    <div class="grid gap-6 xl:grid-cols-2">
      <Card title="Active users">
        <Chart kind="line" label="Users who signed in, per day" {labels} series={[{ label: "Active users", data: r.active_users.map((d) => d.count), colour: "primary" }]} />
      </Card>
      <Card title="Sign-ins and sign-ups">
        <Chart
          kind="line"
          label="Sign-ins and sign-ups per day"
          {labels}
          series={[
            { label: "Sign-ins", data: r.sign_ins.map((d) => d.count), colour: "secondary" },
            { label: "Sign-ups", data: r.sign_ups.map((d) => d.count), colour: "primary" }
          ]}
        />
      </Card>
      <Card title="Failed sign-ins">
        {#if r.failed_sign_ins}
          <Chart kind="line" label="Failed sign-ins per day" {labels} series={[{ label: "Failed sign-ins", data: r.failed_sign_ins.map((d) => d.count), colour: "error" }]} />
        {:else if r.source === "sessions"}
          <Empty message={auditLogNote} />
        {:else}
          <Empty message="Not shown for one organization: a failed sign-in isn't anyone's yet." />
        {/if}
      </Card>
      <Card title="Why sign-ins failed">
        {#if r.failure_reasons && r.failure_reasons.length > 0}
          <Breakdown label="Failed sign-ins by reason" rows={r.failure_reasons.map((f) => ({ name: f.code, count: f.count }))} />
        {:else if r.failure_reasons}
          <Empty message="No failed sign-ins in this range." />
        {:else if r.source === "sessions"}
          <Empty message={auditLogNote} />
        {:else}
          <Empty message="Not shown for one organization: a failed sign-in isn't anyone's yet." />
        {/if}
      </Card>
      <Card title="Sign-ins by method">
        {#if r.sign_ins_by_method === null}
          <Empty message={auditLogNote} />
        {:else if r.sign_ins_by_method.length === 0}
          <Empty message="No sign-ins in this range." />
        {:else}
          <Breakdown label="Sign-ins by method" rows={r.sign_ins_by_method.map((m) => ({ name: m.method, count: m.count }))} />
        {/if}
      </Card>
      <Card title="Sign-ups by method">
        {#if r.sign_ups_by_method === null}
          <Empty message={auditLogNote} />
        {:else if r.sign_ups_by_method.length === 0}
          <Empty message="No sign-ups in this range." />
        {:else}
          <Breakdown label="Sign-ups by method" rows={r.sign_ups_by_method.map((m) => ({ name: m.method, count: m.count }))} />
        {/if}
      </Card>
    </div>

    <section>
      <h2 class="mb-1 text-base font-semibold">Adoption</h2>
      <p class="text-base-content/70 mb-3 text-sm">
        Of the {count(r.adoption.users, "user")}{r.organization_id ? " in this organization" : ""} today, whatever the date range.
      </p>
      <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard title="Verified email" value={percent(r.adoption.verified_email, r.adoption.users)} detail={count(r.adoption.verified_email, "user")} icon={BadgeCheck} />
        {#if r.adoption.two_factor !== null}
          <StatCard title="Two-factor" value={percent(r.adoption.two_factor, r.adoption.users)} detail={count(r.adoption.two_factor, "user")} icon={ShieldCheck} />
        {/if}
        {#if r.adoption.authenticator_app !== null}
          <StatCard title="Authenticator app" value={percent(r.adoption.authenticator_app, r.adoption.users)} detail={count(r.adoption.authenticator_app, "user")} icon={Smartphone} />
        {/if}
        {#if r.adoption.passkey !== null}
          <StatCard title="Passkey" value={percent(r.adoption.passkey, r.adoption.users)} detail={count(r.adoption.passkey, "user")} icon={Fingerprint} />
        {/if}
      </div>
    </section>
  </div>
{:else if loading}
  <Loading />
{/if}
