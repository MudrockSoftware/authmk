<script lang="ts">
  import { resolve } from "$app/paths";
  import ArrowRight from "@lucide/svelte/icons/arrow-right";
  import Building2 from "@lucide/svelte/icons/building-2";
  import CreditCard from "@lucide/svelte/icons/credit-card";
  import Database from "@lucide/svelte/icons/database";
  import FileDiff from "@lucide/svelte/icons/file-diff";
  import Fingerprint from "@lucide/svelte/icons/fingerprint";
  import KeyRound from "@lucide/svelte/icons/key-round";
  import Layers from "@lucide/svelte/icons/layers";
  import LayoutDashboard from "@lucide/svelte/icons/layout-dashboard";
  import Mail from "@lucide/svelte/icons/mail";
  import Network from "@lucide/svelte/icons/network";
  import ShieldCheck from "@lucide/svelte/icons/shield-check";
  import UsersRound from "@lucide/svelte/icons/users-round";
  import GithubIcon from "#lib/components/GithubIcon.svelte";
  import Seo from "#lib/components/Seo.svelte";
  import { site } from "#lib/site.ts";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  const features = [
    {
      icon: Mail,
      title: "Email, password and sessions",
      body: "Sign-up, verification, password reset and sessions in cookies or bearer tokens, with Argon2 hashing.",
      slug: "email-password-and-sessions",
    },
    {
      icon: UsersRound,
      title: "Social sign-in",
      body: "44 providers built in, and any other OpenID Connect or OAuth 2.0 provider, with a line of config each.",
      slug: "social-sign-in",
    },
    {
      icon: Fingerprint,
      title: "Passkeys and two-factor",
      body: "Passkeys, magic links, codes by email or SMS, authenticator apps, backup codes and trusted devices.",
      slug: "sign-in-methods",
    },
    {
      icon: Building2,
      title: "Organizations and access control",
      body: "Members, invitations, teams and roles, with permissions checked without a database call.",
      slug: "organizations-and-access-control",
    },
    {
      icon: KeyRound,
      title: "Enterprise SSO and SCIM",
      body: "Customers sign in with their own OpenID Connect or SAML 2.0 identity provider, and provision people over SCIM 2.0.",
      slug: "enterprise-sso-and-scim",
    },
    {
      icon: Network,
      title: "Your app as an identity provider",
      body: "An OAuth 2.1 and OpenID Connect provider with PKCE, consent, DPoP and dynamic client registration.",
      slug: "oauth-provider",
    },
    {
      icon: CreditCard,
      title: "Payments",
      body: "Stripe, Polar, Chargebee and more behind one set of endpoints, with plans and feature access in config.",
      slug: "payments",
    },
    {
      icon: ShieldCheck,
      title: "Security built in",
      body: "Hashed tokens, origin checks, rate limits, breached-password checks, bot blocking and an audit log.",
      slug: "security",
    },
  ];

  const databases = ["SQLite", "PostgreSQL", "MySQL", "MariaDB"];
</script>

<Seo />

<!-- Introduction -->
<section class="border-base-300 border-b">
  <div class="site-container grid items-center gap-12 py-16 lg:grid-cols-[1fr_minmax(0,1.1fr)] lg:py-24">
    <div>
      <p class="badge badge-outline badge-primary">Version {site.version} · stable API</p>
      <h1 class="mt-5 text-4xl font-bold tracking-tight text-balance sm:text-5xl xl:text-6xl">Authentication for Elixir, built from plugins</h1>
      <p class="text-base-content/80 mt-6 max-w-xl text-lg xl:max-w-2xl xl:text-xl">
        authmk gives your Phoenix or Plug app sign-in, sessions, organizations, single sign-on and payments.
        Each feature is a plugin that brings its own tables, routes and hooks, and works with the Ecto repo
        you already have.
      </p>
      <div class="mt-8 flex flex-wrap gap-3">
        <a href={resolve("/docs")} class="btn btn-primary btn-lg">
          Get started
          <ArrowRight class="size-5" aria-hidden="true" />
        </a>
        <a href={site.github} rel="external" class="btn btn-outline btn-lg">
          <GithubIcon class="size-5" />
          View on GitHub
        </a>
      </div>
    </div>
    <div class="min-w-0">
      <!-- eslint-disable-next-line svelte/no-at-html-tags -- code highlighted at build time. -->
      {@html data.authModule}
    </div>
  </div>
</section>

<!-- Features -->
<section class="site-container py-16 lg:py-24">
  <h2 class="text-3xl font-semibold tracking-tight">What you get</h2>
  <p class="text-base-content/80 mt-3 max-w-2xl">
    Turn on what your app needs. Everything else stays out of your database and your routes.
  </p>
  <ul class="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
    {#each features as feature (feature.slug)}
      <li>
        <a href={resolve("/docs/[slug]", { slug: feature.slug })} class="border-base-300 bg-base-100 hover:border-primary/50 rounded-box flex h-full flex-col border p-5 transition-colors">
          <feature.icon class="text-secondary size-6" strokeWidth={1.5} aria-hidden="true" />
          <h3 class="mt-4 font-semibold">{feature.title}</h3>
          <p class="text-base-content/80 mt-2 text-sm">{feature.body}</p>
        </a>
      </li>
    {/each}
  </ul>
</section>

<!-- Getting started -->
<section class="border-base-300 bg-base-200 border-y">
  <div class="site-container py-16 lg:py-24">
    <h2 class="text-3xl font-semibold tracking-tight">Set up in three steps</h2>
    <ol class="mt-10 space-y-10">
      {#each data.steps as step, position (step.title)}
        <li class="grid gap-4 lg:grid-cols-[20rem_minmax(0,1fr)] lg:gap-10">
          <div class="flex gap-3">
            <span class="bg-primary text-primary-content grid size-8 shrink-0 place-items-center rounded-full text-sm font-semibold">{position + 1}</span>
            <div>
              <h3 class="pt-1 font-semibold">{step.title}</h3>
              <p class="text-base-content/80 mt-1 text-sm">{step.body}</p>
            </div>
          </div>
          <div class="min-w-0 [&_pre]:bg-base-100">
            <!-- eslint-disable-next-line svelte/no-at-html-tags -- code highlighted at build time. -->
            {@html step.html}
          </div>
        </li>
      {/each}
    </ol>
    <p class="mt-10">
      Clients then call <code class="font-mono text-sm">POST /auth/sign-in/email</code>,
      <code class="font-mono text-sm">GET /auth/get-session</code> and the rest.
      <a href={resolve("/docs")} class="link link-primary">Read the overview</a> or
      <a href={resolve("/docs/[slug]", { slug: "phoenix-and-liveview" })} class="link link-primary">set up Phoenix and LiveView</a>.
    </p>
  </div>
</section>

<!-- Design -->
<section class="site-container grid items-start gap-12 py-16 lg:grid-cols-2 lg:py-24">
  <div>
    <h2 class="text-3xl font-semibold tracking-tight">Plugins all the way down</h2>
    <p class="text-base-content/80 mt-4">
      A plugin is a module. It can add tables or fields to the user, serve endpoints, and run hooks before
      and after each endpoint and around every write. Your auth module gets the same hooks, so your rules
      live in one place.
    </p>
    <ul class="mt-8 space-y-5">
      <li class="flex gap-3">
        <Layers class="text-secondary mt-0.5 size-5 shrink-0" aria-hidden="true" />
        <div>
          <h3 class="font-semibold">Schema declared in config</h3>
          <p class="text-base-content/80 mt-1 text-sm">
            Core models, plugin models and your own fields merge into one schema at compile time. It drives
            the Ecto schemas, input validation and migrations, and maps onto tables you already have.
          </p>
        </div>
      </li>
      <li class="flex gap-3">
        <FileDiff class="text-secondary mt-0.5 size-5 shrink-0" aria-hidden="true" />
        <div>
          <h3 class="font-semibold">Migrations from a snapshot</h3>
          <p class="text-base-content/80 mt-1 text-sm">
            <code class="font-mono">mix authmk.gen.migration</code> compares the schema with a snapshot in your
            repository and writes normal Ecto migrations. Destructive changes need your say-so.
          </p>
        </div>
      </li>
      <li class="flex gap-3">
        <Database class="text-secondary mt-0.5 size-5 shrink-0" aria-hidden="true" />
        <div>
          <h3 class="font-semibold">Your database</h3>
          <p class="text-base-content/80 mt-1 text-sm">authmk follows your repo's adapter, with no default:</p>
          <ul class="mt-2 flex flex-wrap gap-2">
            {#each databases as database (database)}
              <li class="badge badge-ghost">{database}</li>
            {/each}
          </ul>
        </div>
      </li>
    </ul>
    <a href={resolve("/docs/[slug]", { slug: "writing-plugins" })} class="btn btn-outline mt-8">
      Write a plugin
      <ArrowRight class="size-4" aria-hidden="true" />
    </a>
  </div>
  <div class="min-w-0">
    <!-- eslint-disable-next-line svelte/no-at-html-tags -- code highlighted at build time. -->
    {@html data.plugin}
  </div>
</section>

<!-- Examples and dashboard -->
<section class="site-container grid gap-6 pb-16 lg:grid-cols-2 lg:pb-24">
  <div class="border-base-300 rounded-box border p-8">
    <h2 class="text-2xl font-semibold tracking-tight">See it in working apps</h2>
    <p class="text-base-content/80 mt-3">
      A Phoenix app with LiveView and a plain Plug app use every plugin, with tests for each. Read their code
      file by file, then run them.
    </p>
    <a href={resolve("/examples")} class="btn btn-primary mt-6">
      Browse the examples
      <ArrowRight class="size-4" aria-hidden="true" />
    </a>
  </div>
  <div class="bg-neutral text-neutral-content rounded-box p-8">
    <LayoutDashboard class="size-6" strokeWidth={1.5} aria-hidden="true" />
    <h2 class="mt-4 text-2xl font-semibold tracking-tight">An admin dashboard, in one line</h2>
    <p class="text-neutral-content/80 mt-3">
      <code class="font-mono text-sm">forward "/admin/auth", Authmk.Dashboard, auth: MyApp.Auth</code> gives
      you analytics, users, organizations, subscriptions, health checks and branding. It's free in development;
      production needs a licence key.
    </p>
    <a href={site.licence} rel="external" class="btn mt-6">Get a licence key</a>
  </div>
</section>
