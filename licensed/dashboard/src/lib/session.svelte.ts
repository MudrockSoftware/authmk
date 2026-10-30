// The signed-in admin and what they may do, loaded once for every page.

import { api, type Me } from "#lib/api.ts";

class Session {
  me = $state<Me | null>(null);
  error = $state<unknown>(null);

  async load() {
    try {
      this.me = await api.me();
    } catch (error) {
      this.error = error;
    }
  }
}

export const session = new Session();
