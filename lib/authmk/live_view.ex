if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Authmk.LiveView do
    @moduledoc """
    The signed-in user in LiveViews: `on_mount` hooks that assign
    `:current_user`, `:current_session` and `:current_principal`, and can
    require a user.

    LiveViews can't read cookies, so a `live_session` hands them the
    session through LiveView's own signed session data: the session token's
    hash (never the token), from the request that rendered the page.
    `Authmk.Phoenix.Router.authmk_live_session/4` sets this up:

        authmk_live_session :signed_in, MyApp.Auth, require: :user, redirect_to: "/sign-in" do
          live "/settings", SettingsLive
        end

    or by hand:

        live_session :signed_in,
          session: {Authmk.LiveView, :session, [MyApp.Auth]},
          on_mount: [{Authmk.LiveView, {:require_user, MyApp.Auth, "/sign-in"}}] do
          live "/settings", SettingsLive
        end

    Hooks:

      * `{:current_user, auth}`: assigns the user and session, `nil` when
        signed out.
      * `{:require_user, auth, redirect_to}`: as above, and sends signed-out
        visitors to `redirect_to`.
      * `{:redirect_if_signed_in, auth, redirect_to}`: for sign-in and
        sign-up pages.
      * `{:require_ability, auth, ability, redirect_to}` and
        `{:require_ability, auth, ability, redirect_to, resource}`: a
        signed-in user with an ability, by `Authmk.Plugins.Gate`; others go
        to `redirect_to`. `resource` is as in `Authmk.Plug.RequireAbility`;
        with a param, every patch to new params is checked again. Events
        aren't: check records with `Authmk.Plugins.Gate.allows?/4` before
        changing them.

    Every mount, including each reconnect, reads the session from the
    store, so a revoked or expired session stops working on the next one.
    To end a session's connected LiveViews at once, broadcast to their
    socket ID after revoking it:

        MyAppWeb.Endpoint.broadcast(Authmk.LiveView.socket_id(session), "disconnect", %{})

    In tests, `Authmk.Testing.sign_in/4` on the conn signs LiveViews in too:

        {:ok, view, _html} = conn |> Authmk.Testing.sign_in(MyApp.Auth, user) |> live("/settings")
    """

    import Phoenix.Component, only: [assign_new: 3]

    alias Authmk.{ConnContext, CookieCache, Cookies, Sessions, Token}
    alias Authmk.Plugins.Gate
    alias Authmk.Plugins.Gate.Page

    @session_key "authmk_session"
    @data_key "authmk_session_data"

    @doc """
    For `live_session`'s `session:` option: the session token's hash, from
    the request's cookie, or nothing when signed out.
    """
    @spec session(Plug.Conn.t(), module()) :: map()
    def session(conn, auth) do
      with {:ok, ctx} <- ConnContext.new(conn, auth),
           {:ok, token} <- Cookies.session_token(ctx) do
        hash = Token.hash(token)
        session = %{@session_key => hash, "live_socket_id" => socket_id(hash)}

        # Stateless sessions are in the cache cookie: LiveViews get its value.
        if ctx.config.session[:stateless],
          do: Map.put(session, @data_key, Cookies.session_data(ctx)),
          else: session
      else
        _signed_out -> %{}
      end
    end

    @doc "The LiveView socket ID of a session's LiveViews (a session, or its token hash)."
    @spec socket_id(struct() | String.t()) :: String.t()
    def socket_id(%{token: hash}), do: socket_id(hash)
    def socket_id(hash) when is_binary(hash), do: "authmk_session:" <> hash

    @doc "The hooks; see the module docs."
    def on_mount({:current_user, auth}, _params, session, socket),
      do: {:cont, assign_current(socket, auth, session)}

    def on_mount({:require_user, auth, redirect_to}, _params, session, socket) do
      socket = assign_current(socket, auth, session)

      if socket.assigns.current_user,
        do: {:cont, socket},
        else: {:halt, Phoenix.LiveView.redirect(socket, to: redirect_to)}
    end

    def on_mount({:redirect_if_signed_in, auth, redirect_to}, _params, session, socket) do
      socket = assign_current(socket, auth, session)

      if socket.assigns.current_user,
        do: {:halt, Phoenix.LiveView.redirect(socket, to: redirect_to)},
        else: {:cont, socket}
    end

    def on_mount({:require_ability, auth, ability, redirect_to}, params, session, socket),
      do: on_mount({:require_ability, auth, ability, redirect_to, nil}, params, session, socket)

    def on_mount(
          {:require_ability, auth, ability, redirect_to, resource},
          params,
          session,
          socket
        ) do
      resource = Page.validate!(resource)
      socket = assign_current(socket, auth, session)

      if allowed?(socket, auth, ability, resource, params) do
        {:cont, recheck_on_patch(socket, auth, ability, redirect_to, resource)}
      else
        {:halt, Phoenix.LiveView.redirect(socket, to: redirect_to)}
      end
    end

    defp allowed?(socket, auth, ability, resource, params) do
      user = socket.assigns.current_user
      params = if is_map(params), do: params, else: %{}
      resource = Page.resource(resource, params, socket.assigns.current_session)
      user != nil and Gate.allows?(auth, user, ability, resource)
    end

    # A patch changes params without mounting again: check the new ones.
    defp recheck_on_patch(socket, auth, ability, redirect_to, {:param, _kind, _name} = resource) do
      Phoenix.LiveView.attach_hook(socket, :authmk_require_ability, :handle_params, fn
        params, _uri, socket ->
          if allowed?(socket, auth, ability, resource, params),
            do: {:cont, socket},
            else: {:halt, Phoenix.LiveView.redirect(socket, to: redirect_to)}
      end)
    end

    defp recheck_on_patch(socket, _auth, _ability, _redirect_to, _resource), do: socket

    # The first, disconnected render reuses what Authmk.Plug.FetchSession
    # assigned on the conn; the connected mount reads the store.
    defp assign_current(socket, auth, session) do
      socket
      |> assign_new(:current_session, fn -> load(auth, session) end)
      |> assign_new(:current_user, fn %{current_session: session} -> session && session.user end)
      |> assign_new(:current_principal, fn %{current_user: user} -> user end)
    end

    defp load(auth, session) do
      config = auth.config()
      ctx = Authmk.Context.new(config)

      if config.session[:stateless],
        do: stateless(ctx, session),
        else: Sessions.fetch_by_token_hash(ctx, session[@session_key])
    end

    defp stateless(ctx, session) do
      case CookieCache.read_value(ctx, session[@data_key], session[@session_key]) do
        {:ok, session, user} -> %{session | user: user}
        :miss -> nil
      end
    end
  end
end
