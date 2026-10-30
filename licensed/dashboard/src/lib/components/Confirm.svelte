<script lang="ts">
  // Asks before an action that's hard to undo. `run` does it; errors show here.
  let {
    title,
    message,
    confirmLabel,
    danger = false,
    run
  }: { title: string; message: string; confirmLabel: string; danger?: boolean; run: () => Promise<void> } = $props();

  let dialog: HTMLDialogElement;
  let busy = $state(false);
  let failure = $state<string | null>(null);

  export function open() {
    failure = null;
    dialog.showModal();
  }

  async function confirm() {
    busy = true;
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
  <div class="modal-box">
    <h3 class="text-lg font-semibold">{title}</h3>
    <p class="text-base-content/80 py-3 text-sm">{message}</p>
    {#if failure}<p role="alert" class="text-error text-sm">{failure}</p>{/if}
    <div class="modal-action">
      <button class="btn btn-ghost" onclick={() => dialog.close()} disabled={busy}>Cancel</button>
      <button class="btn {danger ? 'btn-error' : 'btn-primary'}" onclick={confirm} disabled={busy}>
        {#if busy}<span class="loading loading-spinner loading-sm"></span>{/if}
        {confirmLabel}
      </button>
    </div>
  </div>
  <form method="dialog" class="modal-backdrop"><button>Close</button></form>
</dialog>
