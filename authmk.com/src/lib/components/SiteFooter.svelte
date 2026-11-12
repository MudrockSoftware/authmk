<script lang="ts">
  import { resolve } from "$app/paths";
  import { site } from "#lib/site.ts";
  import Logo from "./Logo.svelte";

  const year = new Date().getFullYear();
  const linkClass = "text-base-content/70 hover:text-base-content text-sm transition-colors";

  const docsLinks = [
    { href: resolve("/docs"), label: "Overview" },
    { href: resolve("/docs/[slug]", { slug: "email-password-and-sessions" }), label: "Email, password and sessions" },
    { href: resolve("/docs/[slug]", { slug: "phoenix-and-liveview" }), label: "Phoenix and LiveView" },
    { href: resolve("/docs/[slug]", { slug: "security" }), label: "Security" },
    { href: resolve("/examples"), label: "Example apps" },
  ];

  const projectLinks = [
    { href: resolve("/docs/[slug]", { slug: "changelog" }), label: "Changelog" },
    { href: resolve("/docs/[slug]", { slug: "security-policy" }), label: "Security policy" },
  ];

  // Mudrock's own pages: authmk's maker, and where licence keys come from.
  const mudrockLinks = [
    { href: site.mudrock, label: "Mudrock Software" },
    { href: `${site.mudrock}/open-source`, label: "Open source at Mudrock" },
    { href: `${site.mudrock}/about`, label: "About Mudrock" },
    { href: `${site.mudrock}/contact`, label: "Contact" },
    { href: site.licence, label: "Licence keys" },
  ];

  const externalLinks = [
    { href: site.hexdocs, label: "API reference" },
    { href: site.hex, label: "Hex package" },
    { href: site.github, label: "GitHub" },
  ];
</script>

<footer class="border-base-300 bg-base-200 border-t">
  <div class="site-container py-12">
    <div class="grid gap-10 sm:grid-cols-2 lg:grid-cols-5">
      <div class="sm:col-span-2">
        <Logo />
        <p class="text-base-content/70 mt-4 max-w-sm text-sm">
          Authentication for Elixir, built from plugins. Made by
          <a href={site.mudrock} rel="external" class="link link-hover">Mudrock Software</a>.
        </p>
      </div>
      <div>
        <h2 class="text-sm font-semibold">Docs</h2>
        <ul class="mt-4 space-y-2.5">
          {#each docsLinks as link (link.href)}
            <li><a href={link.href} class={linkClass}>{link.label}</a></li>
          {/each}
        </ul>
      </div>
      <div>
        <h2 class="text-sm font-semibold">Project</h2>
        <ul class="mt-4 space-y-2.5">
          {#each externalLinks as link (link.href)}
            <li><a href={link.href} rel="external" class={linkClass}>{link.label}</a></li>
          {/each}
          {#each projectLinks as link (link.href)}
            <li><a href={link.href} class={linkClass}>{link.label}</a></li>
          {/each}
        </ul>
      </div>
      <div>
        <h2 class="text-sm font-semibold">Mudrock</h2>
        <ul class="mt-4 space-y-2.5">
          {#each mudrockLinks as link (link.href)}
            <li><a href={link.href} rel="external" class={linkClass}>{link.label}</a></li>
          {/each}
        </ul>
      </div>
    </div>

    <div class="border-base-300 text-base-content/70 mt-10 space-y-1 border-t pt-6 text-xs">
      <p>© {year} <a href={site.mudrock} rel="external" class="link link-hover">{site.legalName}</a></p>
      <p>
        authmk is MIT licensed. The admin dashboard is source available, under
        <a href="https://github.com/MudrockSoftware/authmk/blob/main/licensed/LICENSE.md" rel="external" class="link">its own licence</a>.
      </p>
    </div>
  </div>
</footer>
