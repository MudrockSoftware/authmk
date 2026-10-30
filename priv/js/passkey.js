// authmk passkeys, for Authmk.Components' passkey buttons. Served by the
// auth router at <auth path>/passkey.js. Buttons carry what to do:
//
//   data-authmk-passkey="sign-in" | "register"
//   data-auth-path, data-redirect, data-error-redirect,
//   data-two-factor-redirect, data-name (register)
//
// Clicks are caught on the document, so buttons LiveView adds later work.
(() => {
  "use strict"

  async function post(base, path, body) {
    const response = await fetch(base + path, {
      method: "POST",
      credentials: "same-origin",
      headers: {"content-type": "application/json"},
      body: JSON.stringify(body)
    })
    const json = await response.json().catch(() => ({}))
    if (!response.ok) throw json.error || {code: "passkey_failed"}
    return json
  }

  async function signIn(button) {
    const base = button.dataset.authPath
    const options = await post(base, "/passkey/generate-authenticate-options", {})
    const credential = await navigator.credentials.get({
      publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(options)
    })
    const result = await post(base, "/passkey/verify-authentication", {response: credential.toJSON()})
    if (result.two_factor_redirect) return go(button.dataset.twoFactorRedirect)
    go(button.dataset.redirect)
  }

  async function register(button) {
    const base = button.dataset.authPath
    const options = await post(base, "/passkey/generate-register-options", {})
    const credential = await navigator.credentials.create({
      publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options)
    })
    await post(base, "/passkey/verify-registration", {
      response: credential.toJSON(),
      name: button.dataset.name || undefined
    })
    go(button.dataset.redirect)
  }

  function go(url) {
    window.location.assign(url || "/")
  }

  function fail(button, error) {
    // The browser's own refusals (cancelled, timed out) aren't authmk errors.
    const code = error && typeof error.code === "string" ? error.code : "passkey_cancelled"
    const target = button.dataset.errorRedirect || window.location.pathname
    const separator = target.includes("?") ? "&" : "?"
    go(target + separator + "error=" + encodeURIComponent(code))
  }

  document.addEventListener("click", (event) => {
    const button = event.target.closest("[data-authmk-passkey]")
    if (!button) return
    event.preventDefault()

    if (!window.PublicKeyCredential || !PublicKeyCredential.parseRequestOptionsFromJSON) {
      return fail(button, {code: "passkeys_unsupported"})
    }

    const action = button.dataset.authmkPasskey === "register" ? register : signIn
    button.disabled = true
    action(button).catch((error) => {
      button.disabled = false
      fail(button, error)
    })
  })
})()
