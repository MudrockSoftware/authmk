if Code.ensure_loaded?(Swoosh.Email) do
  defmodule Authmk.Emails do
    @moduledoc """
    Ready-made emails for authmk's callbacks, as `Swoosh.Email`s (add
    `{:swoosh, "~> 1.17"}`). Each has a plain-text and an HTML part, and
    takes the map the callback gets plus `opts`:

      * `:from` - `{"Acme", "no-reply@acme.example"}` or an address (required)
      * `:app_name` - shown in subjects and bodies (default: the config's)

    Send them with your mailer:

        @impl Authmk
        def send_reset_password(data, ctx),
          do: data |> Authmk.Emails.reset_password(ctx, from: @from) |> MyApp.Mailer.deliver()

        def send_magic_link(data, ctx),
          do: data |> Authmk.Emails.magic_link(ctx, from: @from) |> MyApp.Mailer.deliver()

    Everything put in the HTML is escaped. Links are the ones authmk made,
    for your base URL.
    """

    import Swoosh.Email

    alias Authmk.Context

    @doc "For `c:Authmk.send_verification_email/2`."
    @spec verification(map(), Context.t(), keyword()) :: Swoosh.Email.t()
    def verification(%{user: user, url: url}, ctx, opts),
      do:
        link_email(
          user.email,
          ctx,
          opts,
          "Verify your email",
          "Confirm this is your email address.",
          "Verify email",
          url
        )

    @doc "For `c:Authmk.send_reset_password/2`."
    @spec reset_password(map(), Context.t(), keyword()) :: Swoosh.Email.t()
    def reset_password(%{user: user, url: url}, ctx, opts) do
      link_email(
        user.email,
        ctx,
        opts,
        "Reset your password",
        "Someone asked to reset your password. If it was you, choose a new one; if not, ignore this email.",
        "Reset password",
        url
      )
    end

    @doc "For `Authmk.Plugins.MagicLink`'s `send_magic_link`."
    @spec magic_link(map(), Context.t(), keyword()) :: Swoosh.Email.t()
    def magic_link(%{email: email, url: url}, ctx, opts),
      do:
        link_email(
          email,
          ctx,
          opts,
          "Your sign-in link",
          "Use this link to sign in. It works once and expires soon.",
          "Sign in",
          url
        )

    @doc "For `c:Authmk.send_change_email_verification/2`: sent to the new address."
    @spec change_email(map(), Context.t(), keyword()) :: Swoosh.Email.t()
    def change_email(%{new_email: new_email, url: url}, ctx, opts),
      do:
        link_email(
          new_email,
          ctx,
          opts,
          "Confirm your new email",
          "Confirm this address to make it your account's email.",
          "Confirm email",
          url
        )

    @doc "For `c:Authmk.send_delete_account_verification/2`."
    @spec delete_account(map(), Context.t(), keyword()) :: Swoosh.Email.t()
    def delete_account(%{user: user, url: url}, ctx, opts),
      do:
        link_email(
          user.email,
          ctx,
          opts,
          "Confirm deleting your account",
          "This deletes your account for good. If you didn't ask for it, ignore this email.",
          "Delete my account",
          url
        )

    @doc """
    For one-time codes: `Authmk.Plugins.EmailOTP` (`%{email:, otp:, type:}`)
    and `Authmk.Plugins.TwoFactor` (`%{user:, otp:}`).
    """
    @spec otp(map(), Context.t(), keyword()) :: Swoosh.Email.t()
    def otp(%{otp: code} = data, ctx, opts) do
      to = data[:email] || data.user.email
      app = app_name(ctx, opts)
      text = "Your #{app} code is #{code}. It expires soon; don't share it with anyone."

      html =
        layout(app, """
        <p>Your code:</p>
        <p style="font-size:28px;font-weight:bold;letter-spacing:4px">#{escape(code)}</p>
        <p>It expires soon. Don't share it with anyone.</p>
        """)

      build(to, opts, "Your #{app} code", text, html)
    end

    @doc "For `Authmk.Plugins.Organization`'s `send_invitation_email`."
    @spec invitation(map(), Context.t(), keyword()) :: Swoosh.Email.t()
    def invitation(%{email: email, organization: organization} = data, ctx, opts) do
      inviter = data[:inviter] && (Map.get(data.inviter, :name) || Map.get(data.inviter, :email))
      by = if inviter, do: " by #{inviter}", else: ""
      intro = "You're invited#{by} to join #{organization.name} on #{app_name(ctx, opts)}."

      case data[:url] || opts[:accept_url] do
        nil ->
          build(
            email,
            opts,
            "Join #{organization.name}",
            intro <> " Your invitation id is #{data.id}.",
            layout(
              app_name(ctx, opts),
              "<p>#{escape(intro)}</p><p>Invitation: #{escape(data.id)}</p>"
            )
          )

        url ->
          link_email(
            email,
            ctx,
            opts,
            "Join #{organization.name}",
            intro,
            "Accept invitation",
            url
          )
      end
    end

    defp link_email(to, ctx, opts, subject, intro, action, url) do
      app = app_name(ctx, opts)
      text = "#{intro}\n\n#{action}: #{url}\n"

      html =
        layout(app, """
        <p>#{escape(intro)}</p>
        <p><a href="#{escape(url)}" style="display:inline-block;padding:10px 16px;background:#111;color:#fff;border-radius:6px;text-decoration:none">#{escape(action)}</a></p>
        <p style="color:#666;font-size:12px">Or open: #{escape(url)}</p>
        """)

      build(to, opts, subject, text, html)
    end

    defp build(to, opts, subject, text, html) do
      new()
      |> to(to)
      |> from(Keyword.fetch!(opts, :from))
      |> subject(subject)
      |> text_body(text)
      |> html_body(html)
    end

    defp layout(app, content) do
      """
      <!doctype html>
      <html><body style="font-family:system-ui,sans-serif;max-width:480px;margin:auto;padding:24px;color:#111">
      <h2 style="font-size:18px">#{escape(app)}</h2>
      #{content}
      </body></html>
      """
    end

    defp app_name(%Context{config: config}, opts), do: opts[:app_name] || config.app_name

    defp escape(value), do: value |> to_string() |> Plug.HTML.html_escape()
  end
end
