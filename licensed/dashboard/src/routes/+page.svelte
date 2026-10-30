<script lang="ts">
  import Activity from "@lucide/svelte/icons/activity";
  import BadgeCheck from "@lucide/svelte/icons/badge-check";
  import Building2 from "@lucide/svelte/icons/building-2";
  import ShieldCheck from "@lucide/svelte/icons/shield-check";
  import UsersIcon from "@lucide/svelte/icons/users";
  import Avatar from "#lib/components/Avatar.svelte";
  import Chart from "#lib/components/Chart.svelte";
  import Empty from "#lib/components/Empty.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import StatCard from "#lib/components/StatCard.svelte";
  import { api } from "#lib/api.ts";
  import { count, formatDate, percent, timeAgo } from "#lib/format.ts";

  const overview = api.overview();
  const shortDay = (day: string) => new Date(day).toLocaleDateString("en-GB", { day: "numeric", month: "short" });
</script>

<PageHeader title="Overview" description="Your users and how they sign in, over the last 30 days." />

{#await overview}
  <Loading />
{:then data}
  {@const totals = data.totals}
  <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-5">
    <StatCard title="Users" value={totals.users.toLocaleString("en-GB")} detail="{count(data.sign_ups.reduce((sum, d) => sum + d.count, 0), 'user')} joined in 30 days" icon={UsersIcon} />
    <StatCard title="Verified emails" value={percent(totals.verified_users, totals.users)} detail={count(totals.verified_users, "user")} icon={BadgeCheck} />
    {#if totals.two_factor_users !== null}
      <StatCard title="Two-factor" value={percent(totals.two_factor_users, totals.users)} detail={count(totals.two_factor_users, "user")} icon={ShieldCheck} />
    {/if}
    <StatCard title="Active sessions" value={totals.active_sessions.toLocaleString("en-GB")} icon={Activity} />
    {#if totals.organizations !== null}
      <StatCard title="Organizations" value={totals.organizations.toLocaleString("en-GB")} icon={Building2} />
    {/if}
  </div>

  <div class="mt-6 grid gap-4 xl:grid-cols-3">
    <section class="card border-base-300 bg-base-100 border xl:col-span-2">
      <div class="card-body">
        <h2 class="card-title text-base">Sign-ups and sign-ins</h2>
        <Chart
          kind="line"
          label="Sign-ups and sign-ins per day over the last 30 days"
          labels={data.sign_ups.map((d) => shortDay(d.day))}
          series={[
            { label: "Sign-ins", data: data.sign_ins.map((d) => d.count), colour: "secondary" },
            { label: "Sign-ups", data: data.sign_ups.map((d) => d.count), colour: "primary" }
          ]}
        />
      </div>
    </section>

    <section class="card border-base-300 bg-base-100 border">
      <div class="card-body">
        <h2 class="card-title text-base">Sign-in methods</h2>
        {#if data.sign_in_methods.length > 0}
          <Chart
            kind="doughnut"
            label="Accounts by sign-in method"
            labels={data.sign_in_methods.map((m) => m.provider)}
            series={[{ label: "Accounts", data: data.sign_in_methods.map((m) => m.count), colour: "primary" }]}
          />
        {:else}
          <Empty message="No sign-in methods yet." />
        {/if}
      </div>
    </section>
  </div>

  <section class="card border-base-300 bg-base-100 mt-6 border">
    <div class="card-body">
      <div class="flex items-center justify-between">
        <h2 class="card-title text-base">Newest users</h2>
        <a href="#/users" class="link link-primary text-sm">All users</a>
      </div>
      {#if data.recent_users.length === 0}
        <Empty message="No users yet." />
      {:else}
        <ul class="divide-base-300 divide-y">
          {#each data.recent_users as user (user.id)}
            <li>
              <a href="#/users/{user.id}" class="hover:bg-base-200 rounded-field flex items-center gap-3 px-2 py-3">
                <Avatar name={user.name} email={user.email} />
                <div class="min-w-0 flex-1">
                  <div class="truncate text-sm font-medium">{user.name ?? user.email}</div>
                  <div class="text-base-content/70 truncate text-xs">{user.email}</div>
                </div>
                <div class="text-base-content/70 text-right text-xs">
                  <div>Joined {formatDate(user.created_at)}</div>
                  <div>Last seen {timeAgo(user.last_sign_in_at).toLowerCase()}</div>
                </div>
              </a>
            </li>
          {/each}
        </ul>
      {/if}
    </div>
  </section>
{:catch error}
  <Failure {error} />
{/await}
