<script lang="ts">
  import type { Snippet } from "svelte";

  // A form in a dialog. `run` submits it; errors show here, and it closes
  // when done.
  let {
    title,
    submitLabel,
    danger = false,
    run,
    children
  }: { title: string; submitLabel: string; danger?: boolean; run: () => Promise<void>; children: Snippet } = $props();

  let dialog: HTMLDialogElement;
  let busy = $state(false);
  let failure = $state<string | null>(null);

  export function open() {
    failure = null;
    dialog.showModal();
  }

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    busy = true;
    failure = null;
    try {
      await run();
      dialog.close();
    } catch (error) {
      failure = error instanceof Error ? error.message : "That didn't work. Try again.";
    } finally {
      busy = false;
    }
  }
</script>

<dialog bind:this={dialog} class="modal">
  <form class="modal-box" onsubmit={submit}>
    <h3 class="text-lg font-semibold">{title}</h3>
    <div class="flex flex-col gap-3 py-3">{@render children()}</div>
    {#if failure}<p role="alert" class="text-error text-sm">{failure}</p>{/if}
    <div class="modal-action">
      <button type="button" class="btn btn-ghost" onclick={() => dialog.close()} disabled={busy}>Cancel</button>
      <button type="submit" class="btn {danger ? 'btn-error' : 'btn-primary'}" disabled={busy}>
        {#if busy}<span class="loading loading-spinner loading-sm"></span>{/if}
        {submitLabel}
      </button>
    </div>
  </form>
  <form method="dialog" class="modal-backdrop"><button>Close</button></form>
</dialog>
