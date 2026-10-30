<script lang="ts">
  import ImageOff from "@lucide/svelte/icons/image-off";
  import Upload from "@lucide/svelte/icons/upload";
  import BrandingPreview from "#lib/components/BrandingPreview.svelte";
  import Card from "#lib/components/Card.svelte";
  import Failure from "#lib/components/Failure.svelte";
  import Loading from "#lib/components/Loading.svelte";
  import PageHeader from "#lib/components/PageHeader.svelte";
  import TextField from "#lib/components/TextField.svelte";
  import { api, type Branding, type BrandingChanges } from "#lib/api.ts";
  import { isColour } from "#lib/colour.ts";
  import { session } from "#lib/session.svelte.ts";

  // Mudrock's primary colour (app.css), used until the app picks its own.
  const defaultColour = "#6e4a7e";
  const logoTypes = ["image/png", "image/jpeg", "image/webp", "image/gif", "image/svg+xml"];
  const maxLogoBytes = 256 * 1024;

  const editable = $derived(session.me!.can.update_branding);

  let saved = $state<Branding | null>(null);
  let defaultName = $state("");
  let loaded = $state(false);
  let failure = $state<unknown>(null);

  let appName = $state("");
  let colour = $state("");
  // The logo: kept as saved, replaced by a new file, or removed.
  let logo = $state<{ kind: "keep" } | { kind: "new"; type: string; data: string } | { kind: "remove" }>({ kind: "keep" });
  let logoProblem = $state<string | null>(null);
  let saving = $state(false);
  let notice = $state<string | null>(null);

  function reset(branding: Branding | null) {
    saved = branding;
    appName = branding?.app_name ?? "";
    colour = branding?.primary_color ?? "";
    logo = { kind: "keep" };
    logoProblem = null;
  }

  async function load() {
    try {
      const data = await api.branding();
      defaultName = data.default_app_name;
      reset(data.branding);
      loaded = true;
    } catch (error) {
      failure = error;
    }
  }

  load();

  const logoUrl = $derived(
    logo.kind === "new" ? `data:${logo.type};base64,${logo.data}` : logo.kind === "remove" ? null : (saved?.logo_url ?? null)
  );

  function chooseLogo(input: HTMLInputElement) {
    const file = input.files?.[0];
    input.value = "";
    logoProblem = null;
    if (!file) return;
    if (!logoTypes.includes(file.type)) {
      logoProblem = "Logos are PNG, JPEG, WebP, GIF or SVG images.";
      return;
    }
    if (file.size > maxLogoBytes) {
      logoProblem = "Logos can be 256 KB at most.";
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      const data = String(reader.result).split(",")[1] ?? "";
      logo = { kind: "new", type: file.type, data };
    };
    reader.onerror = () => (logoProblem = "The file couldn't be read.");
    reader.readAsDataURL(file);
  }

  // Only what changed.
  const changes = $derived.by(() => {
    const result: BrandingChanges = {};
    if (appName.trim() !== (saved?.app_name ?? "")) result.app_name = appName.trim() || null;
    if (colour !== (saved?.primary_color ?? "")) result.primary_color = colour || null;
    if (logo.kind === "new") result.logo = { type: logo.type, data: logo.data };
    if (logo.kind === "remove") result.logo = null;
    return result;
  });

  const colourValid = $derived(colour === "" || isColour(colour));
  const changed = $derived(Object.keys(changes).length > 0);

  async function save(event: SubmitEvent) {
    event.preventDefault();
    saving = true;
    failure = null;
    notice = null;
    try {
      const { branding } = await api.updateBranding(changes);
      reset(branding);
      // The dashboard takes it on at once.
      session.me!.branding = branding;
      notice = "Branding saved. Pages and emails show it within a minute.";
    } catch (error) {
      failure = error;
    } finally {
      saving = false;
    }
  }
</script>

<PageHeader title="Branding" description="Your app's name, logo and colour, used by this dashboard, authmk's sign-in error page and the emails authmk sends." />

{#if notice}<div role="status" class="alert alert-success alert-soft mb-4">{notice}</div>{/if}
{#if failure}<div class="mb-4"><Failure error={failure} /></div>{/if}

{#if loaded}
  <div class="grid gap-6 xl:grid-cols-2">
    <Card title="Your brand">
      <form class="flex flex-col gap-4" onsubmit={save}>
        <TextField label="App name" placeholder={defaultName} maxlength={100} bind:value={appName} readonly={!editable} hint="Leave it empty to use the name in your config ({defaultName})." />

        <div class="fieldset py-0">
          <span class="fieldset-legend pb-1">Primary colour</span>
          <div class="flex flex-wrap items-center gap-2">
            <input
              type="color"
              class="rounded-field border-base-300 h-10 w-14 cursor-pointer border"
              value={isColour(colour) ? colour : defaultColour}
              oninput={(e) => (colour = e.currentTarget.value)}
              disabled={!editable}
              aria-label="Pick a colour"
            />
            <input class="input w-32 font-mono {colourValid ? '' : 'input-error'}" placeholder={defaultColour} bind:value={colour} readonly={!editable} aria-label="Colour as #rrggbb" />
            {#if editable && colour}<button type="button" class="btn btn-ghost btn-sm" onclick={() => (colour = "")}>Use the default</button>{/if}
          </div>
          <span class="label whitespace-normal">{colourValid ? "For buttons and links. Text on it is black or white, whichever reads better." : "Colours look like #1d4ed8."}</span>
        </div>

        <div class="fieldset py-0">
          <span class="fieldset-legend pb-1">Logo</span>
          {#if editable}
            <div class="flex flex-wrap items-center gap-2">
              <label class="btn btn-sm">
                <Upload class="size-4" aria-hidden="true" /> Choose a file
                <input type="file" class="sr-only" accept={logoTypes.join(",")} onchange={(e) => chooseLogo(e.currentTarget)} />
              </label>
              {#if logoUrl}
                <button type="button" class="btn btn-ghost btn-sm" onclick={() => (logo = { kind: "remove" })}><ImageOff class="size-4" aria-hidden="true" /> Remove the logo</button>
              {/if}
              {#if logo.kind !== "keep"}<button type="button" class="btn btn-ghost btn-sm" onclick={() => (logo = { kind: "keep" })}>Undo</button>{/if}
            </div>
          {/if}
          <span class="label whitespace-normal">PNG, JPEG, WebP, GIF or SVG, at most 256 KB. Square or wide logos work best.</span>
          {#if logoProblem}<p role="alert" class="text-error text-sm">{logoProblem}</p>{/if}
        </div>

        {#if editable}
          <div>
            <button class="btn btn-primary" type="submit" disabled={saving || !changed || !colourValid}>
              {#if saving}<span class="loading loading-spinner loading-sm"></span>{/if}
              Save branding
            </button>
          </div>
        {:else}
          <p class="text-base-content/70 text-sm">Your role can't change the branding.</p>
        {/if}
      </form>
    </Card>

    <Card title="Preview">
      <BrandingPreview appName={appName.trim() || defaultName} colour={isColour(colour) ? colour : defaultColour} logo={logoUrl} />
      <p class="text-base-content/70 text-sm">
        Emails link to the logo on your site, so it shows once your app is reachable from the internet.
        {changed ? "Not saved yet." : ""}
      </p>
    </Card>
  </div>
{:else if !failure}
  <Loading />
{/if}
