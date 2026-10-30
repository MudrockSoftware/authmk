defmodule Authmk.Phoenix.Router do
  @moduledoc """
  Router macros for Phoenix apps.

      import Authmk.Phoenix.Router

      scope "/" do
        authmk_routes "/auth", MyApp.Auth
      end

      scope "/", MyAppWeb do
        pipe_through :browser

        authmk_live_session :signed_out, MyApp.Auth, require: :signed_out, redirect_to: "/" do
          live "/sign-in", SignInLive
        end

        authmk_live_session :signed_in, MyApp.Auth, require: :user, redirect_to: "/sign-in" do
          live "/settings", SettingsLive
        end
      end

  Mount `authmk_routes` outside pipelines that check CSRF tokens: authmk
  checks the Origin of every state-changing request itself. The browser
  pipeline should have `plug Authmk.Plug.FetchSession, auth: MyApp.Auth`,
  so pages and LiveViews render signed in. Both macros only expand to
  Phoenix's own `forward` and `live_session`.
  """

  @doc "Mounts the auth module (its endpoints) at `path`."
  defmacro authmk_routes(path, auth) do
    quote do
      forward unquote(path), unquote(auth)
    end
  end

  @doc """
  A `live_session` whose LiveViews get `:current_user`, `:current_session`
  and `:current_principal` (see `Authmk.LiveView`).

  Options: `require:` `:none` (the default), `:user` (signed-out visitors go
  to `redirect_to:`) or `:signed_out` (signed-in users go to
  `redirect_to:`); `on_mount:`, more hooks to run after authmk's; and
  `live_session`'s other options, like `layout:`.
  """
  defmacro authmk_live_session(name, auth, opts \\ [], do: block) do
    {require, opts} = Keyword.pop(opts, :require, :none)
    {redirect_to, opts} = Keyword.pop(opts, :redirect_to)
    {on_mount, opts} = Keyword.pop(opts, :on_mount, [])

    live_session_opts =
      [
        session: quote(do: {Authmk.LiveView, :session, [unquote(auth)]}),
        on_mount:
          quote(do: [unquote(hook(require, auth, redirect_to)) | List.wrap(unquote(on_mount))])
      ] ++ opts

    # Fully qualified: an alias here would end up in the app's router.
    quote do
      require Phoenix.LiveView.Router

      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      Phoenix.LiveView.Router.live_session(unquote(name), unquote(live_session_opts),
        do: unquote(block)
      )
    end
  end

  defp hook(:none, auth, _redirect_to),
    do: quote(do: {Authmk.LiveView, {:current_user, unquote(auth)}})

  defp hook(:user, auth, redirect_to),
    do:
      quote(
        do: {Authmk.LiveView, {:require_user, unquote(auth), unquote(redirect_to!(redirect_to))}}
      )

  defp hook(:signed_out, auth, redirect_to),
    do:
      quote(
        do:
          {Authmk.LiveView,
           {:redirect_if_signed_in, unquote(auth), unquote(redirect_to!(redirect_to))}}
      )

  defp redirect_to!(path) when is_binary(path), do: path

  defp redirect_to!(_path),
    do: raise(ArgumentError, "authmk_live_session with require: needs redirect_to: \"/path\"")
end
