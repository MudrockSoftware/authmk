// What the last change on a page did: a notice when it worked, or the error
// when it didn't. After each change, the page reloads what it shows.

export class Outcome {
  notice = $state<string | null>(null);
  failure = $state<unknown>(null);
  #reload: () => Promise<void>;

  constructor(reload: () => Promise<void>) {
    this.#reload = reload;
  }

  // After a change made elsewhere (a dialog, which shows its own errors).
  async done(message: string) {
    this.failure = null;
    this.notice = message;
    await this.#reload();
  }

  // For buttons without a dialog: makes the change and shows how it went.
  async attempt(change: () => Promise<unknown>, message: string) {
    try {
      await change();
    } catch (error) {
      this.notice = null;
      this.failure = error;
      return;
    }
    await this.done(message);
  }
}
