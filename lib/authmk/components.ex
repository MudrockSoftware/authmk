if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Authmk.Components do
    @moduledoc """
    Function components for sign-in pages, in dead views and LiveViews.

        import Authmk.Components

        <.sign_in_form redirect_to={~p"/"} error={@error} />

    They're plain HTML forms that post straight to authmk's endpoints, so
    they work without JavaScript, and set the session cookie the usual way
    (LiveViews can't set cookies). On success the browser goes to
    `redirect_to`; on failure back to `error_redirect_to` (the current page
    by default, so pass it) with `?error=<code>`. Pass that code back as
    `error` and the form shows its message:

        def mount(params, _session, socket), do: {:ok, assign(socket, error: params["error"])}

    Only the passkey button needs JavaScript: add `passkey_script/1` to your
    root layout.

    Every component takes `auth_path` (where the auth router is mounted,
    `"/auth"` by default) and `class`, and the forms `input_class` and
    `button_class` (daisyUI's `input` and `btn btn-primary` by default).
    For account pages, see `Authmk.Components.Account`.
    """

    use Phoenix.Component

    alias Authmk.Error

    @doc """
    The message for an error code from `?error=`; a generic one for codes
    authmk doesn't know.
    """
    @spec error_message(String.t() | nil) :: String.t() | nil
    def error_message(nil), do: nil

    def error_message(code),
      do: Error.message_for(code) || "Something went wrong. Please try again."

    attr(:auth_path, :string, default: "/auth")
    attr(:redirect_to, :string, default: "/", doc: "where to go once signed in")
    attr(:error_redirect_to, :string, default: nil, doc: "where to come back on errors")
    attr(:two_factor_redirect_to, :string, default: nil, doc: "the page with `two_factor_form/1`")
    attr(:error, :string, default: nil)
    attr(:remember_me, :boolean, default: true, doc: "show the remember me box")
    attr(:class, :string, default: nil)
    attr(:input_class, :string, default: "input w-full")
    attr(:button_class, :string, default: "btn btn-primary w-full")

    @doc "Email and password sign-in (`Authmk.Plugins.EmailPassword`)."
    def sign_in_form(assigns) do
      ~H"""
      <form method="post" action={@auth_path <> "/sign-in/email"} class={["authmk-form", @class]}>
        <.redirects {assigns} />
        <.error_text error={@error} />
        <label class="authmk-field">
          <span>Email</span>
          <input type="email" name="email" autocomplete="username" required class={@input_class} />
        </label>
        <label class="authmk-field">
          <span>Password</span>
          <input
            type="password"
            name="password"
            autocomplete="current-password"
            required
            class={@input_class}
          />
        </label>
        <label :if={@remember_me} class="authmk-check">
          <input type="hidden" name="remember_me" value="false" />
          <input type="checkbox" name="remember_me" value="true" checked /> Remember me
        </label>
        <button type="submit" class={@button_class}>Sign in</button>
      </form>
      """
    end

    attr(:auth_path, :string, default: "/auth")
    attr(:redirect_to, :string, default: "/", doc: "where to go once signed up")
    attr(:error_redirect_to, :string, default: nil)
    attr(:error, :string, default: nil)
    attr(:class, :string, default: nil)
    attr(:input_class, :string, default: "input w-full")
    attr(:button_class, :string, default: "btn btn-primary w-full")

    @doc "Sign-up with a name, email and password."
    def sign_up_form(assigns) do
      assigns = assign(assigns, :two_factor_redirect_to, nil)

      ~H"""
      <form method="post" action={@auth_path <> "/sign-up/email"} class={["authmk-form", @class]}>
        <.redirects {assigns} />
        <.error_text error={@error} />
        <label class="authmk-field">
          <span>Name</span>
          <input type="text" name="name" autocomplete="name" required class={@input_class} />
        </label>
        <label class="authmk-field">
          <span>Email</span>
          <input type="email" name="email" autocomplete="email" required class={@input_class} />
        </label>
        <label class="authmk-field">
          <span>Password</span>
          <input
            type="password"
            name="password"
            autocomplete="new-password"
            required
            class={@input_class}
          />
        </label>
        <button type="submit" class={@button_class}>Create account</button>
      </form>
      """
    end

    attr(:auth_path, :string, default: "/auth")

    attr(:redirect_to, :string,
      required: true,
      doc: "where to go after asking: say the email is on its way"
    )

    attr(:reset_url, :string,
      required: true,
      doc: "your page with `reset_password_form/1`; the email link leads there with `?token=`"
    )

    attr(:error_redirect_to, :string, default: nil)
    attr(:error, :string, default: nil)
    attr(:class, :string, default: nil)
    attr(:input_class, :string, default: "input w-full")
    attr(:button_class, :string, default: "btn btn-primary w-full")

    @doc """
    Asks for a password reset email. The answer is the same whether or not
    the email has an account.
    """
    def forgot_password_form(assigns) do
      assigns = assign(assigns, :two_factor_redirect_to, nil)

      ~H"""
      <form
        method="post"
        action={@auth_path <> "/request-password-reset"}
        class={["authmk-form", @class]}
      >
        <.redirects {assigns} />
        <input type="hidden" name="redirect_to" value={@reset_url} />
        <.error_text error={@error} />
        <label class="authmk-field">
          <span>Email</span>
          <input type="email" name="email" autocomplete="email" required class={@input_class} />
        </label>
        <button type="submit" class={@button_class}>Send reset link</button>
      </form>
      """
    end

    attr(:auth_path, :string, default: "/auth")
    attr(:token, :string, required: true, doc: "`?token=` from the email link")

    attr(:redirect_to, :string,
      required: true,
      doc: "where to go once reset, like the sign-in page"
    )

    attr(:error_redirect_to, :string, default: nil)
    attr(:error, :string, default: nil)
    attr(:class, :string, default: nil)
    attr(:input_class, :string, default: "input w-full")
    attr(:button_class, :string, default: "btn btn-primary w-full")

    @doc "Sets a new password with the token from the reset email."
    def reset_password_form(assigns) do
      assigns = assign(assigns, :two_factor_redirect_to, nil)

      ~H"""
      <form method="post" action={@auth_path <> "/reset-password"} class={["authmk-form", @class]}>
        <.redirects {assigns} />
        <input type="hidden" name="token" value={@token} />
        <.error_text error={@error} />
        <label class="authmk-field">
          <span>New password</span>
          <input
            type="password"
            name="new_password"
            autocomplete="new-password"
            required
            class={@input_class}
          />
        </label>
        <button type="submit" class={@button_class}>Set password</button>
      </form>
      """
    end

    attr(:auth_path, :string, default: "/auth")
    attr(:method, :atom, values: [:totp, :otp, :backup_code], default: :totp)
    attr(:redirect_to, :string, default: "/")
    attr(:error_redirect_to, :string, default: nil)
    attr(:error, :string, default: nil)
    attr(:trust_device, :boolean, default: true, doc: "show the trust this device box")
    attr(:class, :string, default: nil)
    attr(:input_class, :string, default: "input w-full")
    attr(:button_class, :string, default: "btn btn-primary w-full")

    @doc """
    The second step of a sign-in (`Authmk.Plugins.TwoFactor`): a code from
    an authenticator app (`:totp`), one sent by email or SMS (`:otp`), or a
    backup code.
    """
    def two_factor_form(assigns) do
      assigns =
        assigns
        |> assign(:two_factor_redirect_to, nil)
        |> assign(:path, two_factor_path(assigns.method))

      ~H"""
      <form method="post" action={@auth_path <> @path} class={["authmk-form", @class]}>
        <.redirects {assigns} />
        <.error_text error={@error} />
        <label class="authmk-field">
          <span>{if @method == :backup_code, do: "Backup code", else: "Code"}</span>
          <input
            type="text"
            name="code"
            autocomplete="one-time-code"
            inputmode={if @method != :backup_code, do: "numeric"}
            required
            class={@input_class}
          />
        </label>
        <label :if={@trust_device} class="authmk-check">
          <input type="hidden" name="trust_device" value="false" />
          <input type="checkbox" name="trust_device" value="true" /> Trust this device
        </label>
        <button type="submit" class={@button_class}>Verify</button>
      </form>
      """
    end

    defp two_factor_path(:totp), do: "/two-factor/verify-totp"
    defp two_factor_path(:otp), do: "/two-factor/verify-otp"
    defp two_factor_path(:backup_code), do: "/two-factor/verify-backup-code"

    attr(:auth_path, :string, default: "/auth")
    attr(:action, :atom, values: [:sign_in, :register], default: :sign_in)
    attr(:redirect_to, :string, default: "/")
    attr(:error_redirect_to, :string, default: nil)
    attr(:two_factor_redirect_to, :string, default: nil)
    attr(:name, :string, default: nil, doc: "for `:register`: the passkey's name")
    attr(:class, :string, default: "btn w-full")
    slot(:inner_block)

    @doc """
    Signs in with a passkey, or registers one for the signed-in user
    (`action={:register}`). Needs `passkey_script/1` in the layout.
    """
    def passkey_button(assigns) do
      ~H"""
      <button
        type="button"
        class={@class}
        data-authmk-passkey={if @action == :register, do: "register", else: "sign-in"}
        data-auth-path={@auth_path}
        data-redirect={@redirect_to}
        data-error-redirect={@error_redirect_to}
        data-two-factor-redirect={@two_factor_redirect_to}
        data-name={@name}
      >
        {render_slot(@inner_block) ||
          if @action == :register, do: "Add a passkey", else: "Sign in with a passkey"}
      </button>
      """
    end

    attr(:auth_path, :string, default: "/auth")

    @doc "The script `passkey_button/1` needs, once, in the root layout's `<head>`."
    def passkey_script(assigns) do
      ~H"""
      <script defer src={@auth_path <> "/passkey.js"}>
      </script>
      """
    end

    attr(:error, :string, default: nil)

    @doc false
    def error_text(assigns) do
      ~H"""
      <p :if={@error} class="authmk-error text-error" role="alert">{error_message(@error)}</p>
      """
    end

    # Where authmk sends the browser after the post (Authmk.Router.Form).
    defp redirects(assigns) do
      ~H"""
      <input type="hidden" name="authmk_redirect" value={@redirect_to} />
      <input
        :if={@error_redirect_to}
        type="hidden"
        name="authmk_error_redirect"
        value={@error_redirect_to}
      />
      <input
        :if={@two_factor_redirect_to}
        type="hidden"
        name="authmk_two_factor_redirect"
        value={@two_factor_redirect_to}
      />
      """
    end
  end
end
