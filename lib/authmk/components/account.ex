if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Authmk.Components.Account do
    @moduledoc """
    Function components for account pages: the user's name, email and
    password, their sessions, signing out, and their organizations.

        import Authmk.Components.Account

        <.account_settings
          user={@current_user}
          sessions={Authmk.Sessions.list(...)}  # or your own loading
          current_session={@current_session}
          redirect_to={~p"/settings"}
          error={@error}
        />

    Like `Authmk.Components`, they're HTML forms posting to authmk's
    endpoints: after each change the browser comes back to `redirect_to`,
    or with `?error=<code>` to `error_redirect_to` (the page itself by
    default). Each piece is a component of its own too.
    """

    use Phoenix.Component

    import Authmk.Components, only: [error_text: 1]

    @shared [
      auth_path: "/auth",
      input_class: "input w-full",
      button_class: "btn btn-primary"
    ]

    attr(:user, :map, required: true)
    attr(:sessions, :list, default: nil, doc: "the user's sessions; leave out to hide them")
    attr(:current_session, :map, default: nil)
    attr(:redirect_to, :string, required: true)
    attr(:error_redirect_to, :string, default: nil)
    attr(:error, :string, default: nil)
    attr(:auth_path, :string, default: @shared[:auth_path])
    attr(:class, :string, default: nil)
    attr(:input_class, :string, default: @shared[:input_class])
    attr(:button_class, :string, default: @shared[:button_class])

    @doc "Name, email, password, sessions and sign out, in one."
    def account_settings(assigns) do
      ~H"""
      <div class={["authmk-account", @class]}>
        <.error_text error={@error} />
        <.profile_form {forms(assigns)} user={@user} />
        <.change_email_form {forms(assigns)} user={@user} />
        <.change_password_form {forms(assigns)} />
        <.session_list
          :if={@sessions}
          {forms(assigns)}
          sessions={@sessions}
          current_session={@current_session}
        />
        <.sign_out_button auth_path={@auth_path} redirect_to="/" />
      </div>
      """
    end

    # What every form of the page shares; errors show once, at the top.
    defp forms(assigns) do
      Map.take(assigns, [
        :auth_path,
        :redirect_to,
        :error_redirect_to,
        :input_class,
        :button_class
      ])
    end

    attr(:user, :map, required: true)
    attr(:redirect_to, :string, required: true)
    attr(:error_redirect_to, :string, default: nil)
    attr(:auth_path, :string, default: @shared[:auth_path])
    attr(:input_class, :string, default: @shared[:input_class])
    attr(:button_class, :string, default: @shared[:button_class])

    @doc "Changes the user's name."
    def profile_form(assigns) do
      ~H"""
      <form method="post" action={@auth_path <> "/update-user"} class="authmk-form">
        <.redirects {assigns} />
        <label class="authmk-field">
          <span>Name</span>
          <input type="text" name="name" value={@user.name} required class={@input_class} />
        </label>
        <button type="submit" class={@button_class}>Save</button>
      </form>
      """
    end

    attr(:user, :map, required: true)
    attr(:redirect_to, :string, required: true)
    attr(:error_redirect_to, :string, default: nil)
    attr(:auth_path, :string, default: @shared[:auth_path])
    attr(:input_class, :string, default: @shared[:input_class])
    attr(:button_class, :string, default: @shared[:button_class])

    @doc "Changes the user's email: a link goes to the new address to confirm it."
    def change_email_form(assigns) do
      ~H"""
      <form method="post" action={@auth_path <> "/change-email"} class="authmk-form">
        <.redirects {assigns} />
        <input type="hidden" name="callback_url" value={@redirect_to} />
        <label class="authmk-field">
          <span>Email</span>
          <input type="email" name="new_email" value={@user.email} required class={@input_class} />
        </label>
        <button type="submit" class={@button_class}>Change email</button>
      </form>
      """
    end

    attr(:redirect_to, :string, required: true)
    attr(:error_redirect_to, :string, default: nil)
    attr(:auth_path, :string, default: @shared[:auth_path])
    attr(:input_class, :string, default: @shared[:input_class])
    attr(:button_class, :string, default: @shared[:button_class])

    @doc "Changes the password, signing out other sessions."
    def change_password_form(assigns) do
      ~H"""
      <form method="post" action={@auth_path <> "/change-password"} class="authmk-form">
        <.redirects {assigns} />
        <input type="hidden" name="revoke_other_sessions" value="true" />
        <label class="authmk-field">
          <span>Current password</span>
          <input
            type="password"
            name="current_password"
            autocomplete="current-password"
            required
            class={@input_class}
          />
        </label>
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
        <button type="submit" class={@button_class}>Change password</button>
      </form>
      """
    end

    attr(:sessions, :list, required: true)
    attr(:current_session, :map, default: nil)
    attr(:redirect_to, :string, required: true)
    attr(:error_redirect_to, :string, default: nil)
    attr(:auth_path, :string, default: @shared[:auth_path])
    attr(:input_class, :string, default: @shared[:input_class])
    attr(:button_class, :string, default: "btn btn-sm")

    @doc "The user's sessions, each with a sign-out button, except this one."
    def session_list(assigns) do
      ~H"""
      <ul class="authmk-sessions">
        <li :for={session <- @sessions}>
          <span>{session.user_agent || "Unknown device"}</span>
          <span :if={session.ip_address}>{session.ip_address}</span>
          <span :if={current?(session, @current_session)}>This device</span>
          <form
            :if={!current?(session, @current_session)}
            method="post"
            action={@auth_path <> "/revoke-session"}
          >
            <.redirects {assigns} />
            <input type="hidden" name="session_id" value={session.id} />
            <button type="submit" class={@button_class}>Sign out</button>
          </form>
        </li>
      </ul>
      """
    end

    defp current?(session, %{id: id}), do: session.id == id
    defp current?(_session, _current), do: false

    attr(:auth_path, :string, default: @shared[:auth_path])
    attr(:redirect_to, :string, default: "/")
    attr(:class, :string, default: "btn")
    slot(:inner_block)

    @doc "Signs out of this session."
    def sign_out_button(assigns) do
      ~H"""
      <form method="post" action={@auth_path <> "/sign-out"} class="authmk-sign-out">
        <input type="hidden" name="authmk_redirect" value={@redirect_to} />
        <button type="submit" class={@class}>{render_slot(@inner_block) || "Sign out"}</button>
      </form>
      """
    end

    attr(:organizations, :list,
      required: true,
      doc: "the user's, from `Authmk.Plugins.Organization.list_for_user/2`"
    )

    attr(:active_organization_id, :any,
      default: nil,
      doc: "the session's `active_organization_id`"
    )

    attr(:redirect_to, :string, required: true)
    attr(:error_redirect_to, :string, default: nil)
    attr(:auth_path, :string, default: @shared[:auth_path])
    attr(:class, :string, default: nil)
    attr(:input_class, :string, default: "select")
    attr(:button_class, :string, default: "btn")

    @doc "Picks the session's active organization (`Authmk.Plugins.Organization`)."
    def organization_switcher(assigns) do
      ~H"""
      <form
        method="post"
        action={@auth_path <> "/organization/set-active"}
        class={["authmk-organizations", @class]}
      >
        <.redirects {assigns} />
        <select name="organization_id" class={@input_class} aria-label="Organization">
          <option
            :for={organization <- @organizations}
            value={organization.id}
            selected={to_string(organization.id) == to_string(@active_organization_id)}
          >
            {organization.name}
          </option>
        </select>
        <button type="submit" class={@button_class}>Switch</button>
      </form>
      """
    end

    defp redirects(assigns) do
      ~H"""
      <input type="hidden" name="authmk_redirect" value={@redirect_to} />
      <input
        :if={@error_redirect_to}
        type="hidden"
        name="authmk_error_redirect"
        value={@error_redirect_to}
      />
      """
    end
  end
end
