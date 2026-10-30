<script lang="ts">
  import "../app.css";
  import { untrack, type Snippet } from "svelte";
  import { page } from "$app/state";
  import Bot from "@lucide/svelte/icons/bot";
  import Building2 from "@lucide/svelte/icons/building-2";
  import ChartLine from "@lucide/svelte/icons/chart-line";
  import CreditCard from "@lucide/svelte/icons/credit-card";
  import KeyRound from "@lucide/svelte/icons/key-round";
  import LayoutDashboard from "@lucide/svelte/icons/layout-dashboard";
  import LogIn from "@lucide/svelte/icons/log-in";
  import Menu from "@lucide/svelte/icons/menu";
  import Moon from "@lucide/svelte/icons/moon";
  import Palette from "@lucide/svelte/icons/palette";
  import Plug from "@lucide/svelte/icons/plug";
  import ScrollText from "@lucide/svelte/icons/scroll-text";
  import ShieldAlert from "@lucide/svelte/icons/shield-alert";
  import Sun from "@lucide/svelte/icons/sun";
  import UsersIcon from "@lucide/svelte/icons/users";
  import Avatar from "#lib/components/Avatar.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import { ApiError } from "#lib/api.ts";
  import { contentColour, isColour } from "#lib/colour.ts";
  import { session } from "#lib/session.svelte.ts";
  import { theme } from "#lib/theme.svelte.ts";

  let { children }: { children: Snippet } = $props();

  session.load();

  const me = $derived(session.me);

  const links = $derived(
    [
      { href: "#/", label: "Overview", icon: LayoutDashboard, show: true },
      { href: "#/analytics", label: "Analytics", icon: ChartLine, show: true },
      { href: "#/users", label: "Users", icon: UsersIcon, show: true },
      { href: "#/organizations", label: "Organizations", icon: Building2, show: me?.features.organizations },
      { href: "#/payments", label: "Payments", icon: CreditCard, show: me?.features.payments },
      { href: "#/sso", label: "SSO and SCIM", icon: KeyRound, show: me?.features.sso || me?.features.scim },
      { href: "#/service-accounts", label: "Service accounts", icon: Bot, show: me?.features.service_accounts },
      { href: "#/events", label: "Audit log", icon: ScrollText, show: me?.features.audit_log },
      { href: "#/integrations", label: "Integrations", icon: Plug, show: true },
      { href: "#/branding", label: "Branding", icon: Palette, show: me?.features.branding }
    ].filter((link) => link.show)
  );

  // The app's branding, over Mudrock's theme: its name, logo and colour.
  const branding = $derived(me?.branding ?? null);
  const appName = $derived(branding?.app_name ?? (me && me.app_name !== "authmk" ? me.app_name : null));
  let logoFailed = $state(false);

  $effect(() => {
    void branding?.logo_url;
    logoFailed = false;
  });

  $effect(() => {
    const root = document.documentElement.style;
    const colour = branding?.primary_color;
    if (isColour(colour)) {
      root.setProperty("--color-primary", colour);
      root.setProperty("--color-primary-content", contentColour(colour));
    } else {
      root.removeProperty("--color-primary");
      root.removeProperty("--color-primary-content");
    }
    // Charts read the colours when they draw.
    untrack(() => theme.version++);
  });

  function active(href: string): boolean {
    const path = href.slice(1);
    return path === "/" ? page.url.hash === "" || page.url.hash === "#/" : page.url.hash.startsWith(`#${path}`);
  }

  let drawer = $state(false);
</script>

<svelte:head><title>{appName ? `${appName} · authmk dashboard` : "authmk dashboard"}</title></svelte:head>

{#if session.error}
  <main class="flex min-h-screen items-center justify-center p-6">
    <div class="card border-base-300 bg-base-100 max-w-md border">
      <div class="card-body items-center text-center">
        {#if session.error instanceof ApiError && session.error.status === 401}
          <LogIn class="text-primary size-8" aria-hidden="true" />
          <h1 class="text-xl font-semibold">Sign in to continue</h1>
          <p class="text-base-content/70 text-sm">The dashboard is for admins. Sign in to the app, then come back.</p>
        {:else}
          <ShieldAlert class="text-error size-8" aria-hidden="true" />
          <h1 class="text-xl font-semibold">You can't open the dashboard</h1>
          <p class="text-base-content/70 text-sm">
            {session.error instanceof Error ? session.error.message : "Something went wrong. Try again."}
          </p>
        {/if}
        <a class="btn btn-primary mt-2" href="/">Go to the app</a>
      </div>
    </div>
  </main>
{:else if !me}
  <Loading />
{:else}
  <div class="drawer lg:drawer-open">
    <input id="nav" type="checkbox" class="drawer-toggle" bind:checked={drawer} />

    <div class="drawer-content flex min-h-screen flex-col">
      <header class="navbar border-base-300 bg-base-100 sticky top-0 z-10 border-b px-4">
        <label for="nav" class="btn btn-ghost btn-square lg:hidden" aria-label="Open the menu">
          <Menu class="size-5" />
        </label>
        <div class="flex-1"></div>
        <button class="btn btn-ghost btn-square" onclick={() => theme.toggle()} aria-label={theme.dark ? "Use the light theme" : "Use the dark theme"}>
          {#if theme.dark}<Sun class="size-5" />{:else}<Moon class="size-5" />{/if}
        </button>
        <div class="ml-2 flex items-center gap-3">
          <Avatar name={me.user.name} email={me.user.email} size="size-8" />
          <div class="hidden text-sm leading-tight sm:block">
            <div class="font-medium">{me.user.name ?? me.user.email}</div>
            <div class="text-base-content/70 text-xs">{me.user.email}</div>
          </div>
        </div>
      </header>

      <main class="w-full min-w-0 flex-1 p-6">
        {@render children()}
      </main>
    </div>

    <div class="drawer-side z-20">
      <label for="nav" aria-label="Close the menu" class="drawer-overlay"></label>
      <aside class="border-base-300 bg-base-200 flex min-h-full w-64 flex-col border-r">
        <div class="flex items-center gap-2 px-5 py-5">
          {#if branding?.logo_url && !logoFailed}
            <img src={branding.logo_url} alt="" class="rounded-field size-8 object-contain" onerror={() => (logoFailed = true)} />
          {:else}
            <span class="bg-primary text-primary-content rounded-field grid size-8 place-items-center text-sm font-bold">{appName ? appName.charAt(0).toUpperCase() : "a"}</span>
          {/if}
          <div class="min-w-0 leading-tight">
            <div class="truncate font-semibold">{appName ?? "authmk"}</div>
            <div class="text-base-content/70 text-xs">Admin dashboard</div>
          </div>
        </div>
        <ul class="menu w-full gap-1 px-3">
          {#each links as link (link.href)}
            {@const Icon = link.icon}
            <li>
              <a
                href={link.href}
                class={active(link.href) ? "bg-primary text-primary-content hover:bg-primary" : ""}
                aria-current={active(link.href) ? "page" : undefined}
                onclick={() => (drawer = false)}
              >
                <Icon class="size-4" aria-hidden="true" />
                {link.label}
              </a>
            </li>
          {/each}
        </ul>
        <div class="text-base-content/60 mt-auto px-5 py-4 text-xs">© 2026 MUDROCK SOFTWARE LTD</div>
      </aside>
    </div>
  </div>
{/if}
