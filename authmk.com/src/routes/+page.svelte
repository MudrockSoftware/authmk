<script lang="ts">
  import { resolve } from "$app/paths";
  import ArrowRight from "@lucide/svelte/icons/arrow-right";
  import Building2 from "@lucide/svelte/icons/building-2";
  import CreditCard from "@lucide/svelte/icons/credit-card";
  import Fingerprint from "@lucide/svelte/icons/fingerprint";
  import KeyRound from "@lucide/svelte/icons/key-round";
  import Mail from "@lucide/svelte/icons/mail";
  import UsersRound from "@lucide/svelte/icons/users-round";
  import logo from "#lib/assets/logo.svg";
  import GithubIcon from "#lib/components/GithubIcon.svelte";
  import Seo from "#lib/components/Seo.svelte";
  import { site } from "#lib/site.ts";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  // A few plugins to start with; the overview lists them all.
  const features = [
    { icon: Mail, title: "Email and password", body: "Sign-up, verification, resets and sessions.", slug: "email-password-and-sessions" },
    { icon: UsersRound, title: "Social sign-in", body: "GitHub, Google and 40 more providers.", slug: "social-sign-in" },
    { icon: Fingerprint, title: "Passkeys and two-factor", body: "Passkeys, magic links and one-time codes.", slug: "sign-in-methods" },
    { icon: Building2, title: "Organizations", body: "Teams, invitations, roles and permissions.", slug: "organizations-and-access-control" },
    { icon: KeyRound, title: "Enterprise SSO", body: "Company sign-in with OIDC or SAML, and SCIM.", slug: "enterprise-sso-and-scim" },
    { icon: CreditCard, title: "Payments", body: "Subscriptions with Stripe, Polar and others.", slug: "payments" },
  ];
</script>

<Seo />

<!-- Introduction -->
<section class="site-container grid items-center gap-12 py-16 lg:grid-cols-2 lg:gap-16 lg:py-28">
  <div>
    <img src={logo} alt="" width="138" height="96" class="h-20 w-auto lg:h-24" />
    <h1 class="mt-8 text-4xl font-bold tracking-tight text-balance sm:text-5xl xl:text-6xl">
      Authentication for Elixir, built from plugins
    </h1>
    <p class="text-base-content/80 mt-6 max-w-xl text-lg xl:text-xl">
      Sign-in, sessions, organizations and single sign-on for your Phoenix or Plug app. Add the plugins you
      need; authmk uses the Ecto repo you already have.
    </p>
    <div class="mt-10 flex flex-wrap gap-3">
      <a href={resolve("/docs")} class="btn btn-primary btn-lg">
        Get started
        <ArrowRight class="size-5" aria-hidden="true" />
      </a>
      <a href={site.github} rel="external" class="btn btn-ghost btn-lg">
        <GithubIcon class="size-5" />
        GitHub
      </a>
    </div>
  </div>
  <div class="min-w-0">
    <!-- eslint-disable-next-line svelte/no-at-html-tags -- code highlighted at build time. -->
    {@html data.authModule}
  </div>
</section>

<!-- Features -->
<section class="border-base-300 bg-base-200 border-y">
  <div class="site-container py-16 lg:py-24">
    <h2 class="text-3xl font-semibold tracking-tight">Turn on what you need</h2>
    <ul class="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {#each features as feature (feature.slug)}
        <li>
          <a
            href={resolve("/docs/[slug]", { slug: feature.slug })}
            class="bg-base-100 hover:border-primary/50 rounded-box flex h-full items-start gap-4 border border-transparent p-6 transition-colors"
          >
            <feature.icon class="text-secondary size-7 shrink-0" strokeWidth={1.5} aria-hidden="true" />
            <span>
              <span class="block text-lg font-semibold">{feature.title}</span>
              <span class="text-base-content/70 mt-1 block">{feature.body}</span>
            </span>
          </a>
        </li>
      {/each}
    </ul>
    <a href={resolve("/docs")} class="link link-primary mt-8 inline-flex items-center gap-1">
      See every plugin
      <ArrowRight class="size-4" aria-hidden="true" />
    </a>
  </div>
</section>

<!-- Getting started -->
<section class="site-container py-16 lg:py-24">
  <h2 class="text-3xl font-semibold tracking-tight">Set up in three steps</h2>
  <ol class="mt-10 grid gap-8 lg:grid-cols-3">
    {#each data.steps as step, position (step.title)}
      <li class="flex min-w-0 flex-col gap-4">
        <h3 class="flex items-center gap-3 text-lg font-semibold">
          <span class="bg-primary text-primary-content grid size-8 shrink-0 place-items-center rounded-full text-sm">{position + 1}</span>
          {step.title}
        </h3>
        <div class="min-w-0 flex-1 [&_pre]:h-full">
          <!-- eslint-disable-next-line svelte/no-at-html-tags -- code highlighted at build time. -->
          {@html step.html}
        </div>
      </li>
    {/each}
  </ol>
  <a href={resolve("/docs")} class="btn btn-outline mt-10">
    Read the full setup
    <ArrowRight class="size-4" aria-hidden="true" />
  </a>
</section>

<!-- Examples and dashboard -->
<section class="site-container grid gap-6 pb-16 lg:grid-cols-2 lg:pb-24">
  <div class="border-base-300 rounded-box border p-8 lg:p-10">
    <h2 class="text-2xl font-semibold tracking-tight">See it in working apps</h2>
    <p class="text-base-content/80 mt-3">A Phoenix app and a Plug app, with every plugin wired in.</p>
    <a href={resolve("/examples")} class="btn btn-primary mt-6">
      Browse the examples
      <ArrowRight class="size-4" aria-hidden="true" />
    </a>
  </div>
  <div class="bg-neutral text-neutral-content rounded-box p-8 lg:p-10">
    <h2 class="text-2xl font-semibold tracking-tight">An admin dashboard, in one line</h2>
    <p class="text-neutral-content/80 mt-3">Users, organizations, subscriptions and analytics. Free in development.</p>
    <a href={site.licence} rel="external" class="btn mt-6">Get a licence key</a>
  </div>
</section>
