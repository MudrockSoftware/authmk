<script lang="ts">
  import { contentColour } from "#lib/colour.ts";

  // How the branding looks: a page header with the logo and name, and a button.
  let { appName, colour, logo }: { appName: string; colour: string; logo: string | null } = $props();
</script>

<div class="rounded-box border-base-300 overflow-hidden border bg-white text-[#1c1f24]" aria-label="Preview">
  <div class="flex items-center gap-3 border-b border-[#e2dcd2] px-4 py-3">
    {#if logo}
      <img src={logo} alt="" class="h-8 max-w-32 object-contain" />
    {:else}
      <span class="rounded-field grid size-8 place-items-center text-sm font-bold" style:background={colour} style:color={contentColour(colour)}>
        {appName.charAt(0).toUpperCase()}
      </span>
    {/if}
    <span class="font-semibold">{appName}</span>
  </div>
  <div class="flex flex-col items-start gap-3 p-4">
    <p class="text-sm">Confirm your email address to finish signing up.</p>
    <span class="btn pointer-events-none border-0" style:background={colour} style:color={contentColour(colour)}>Confirm email</span>
    <span class="text-sm underline" style:color={colour}>Didn't ask for this?</span>
  </div>
</div>
