if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Authmk.Install do
    @shortdoc "Installs authmk into your app"

    @moduledoc """
    Installs authmk with email and password sign-in:

        mix igniter.install authmk

    or, with authmk already in your deps, `mix authmk.install`. It:

      * creates `MyApp.Auth`, sending emails through your Swoosh mailer when
        the app has one (`MyApp.Mailer`)
      * starts it after your repo in your supervision tree
      * configures `base_url`, development and test secrets, and fast test
        settings; production reads `AUTHMK_SECRET` and `AUTHMK_BASE_URL`
      * mounts it at `/auth` in your Phoenix router (or `Plug.Router`), and
        loads the signed-in user in Phoenix's `:browser` pipeline
      * generates the migration

    ## Options

      * `--auth` - the auth module name (default `MyApp.Auth`)
      * `--repo` - the Ecto repo, when the app has several
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common, as: CodeCommon
    alias Igniter.Code.Function, as: CodeFunction
    alias Igniter.Code.Module, as: CodeModule
    alias Igniter.Libs.Ecto, as: IgniterEcto
    alias Igniter.Libs.Phoenix, as: IgniterPhoenix
    alias Igniter.Project.Application, as: ProjectApplication
    alias Igniter.Project.Config, as: ProjectConfig
    alias Igniter.Project.Module, as: ProjectModule

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :authmk,
        example: "mix igniter.install authmk",
        schema: [auth: :string, repo: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app = ProjectApplication.app_name(igniter)
      options = igniter.args.options
      auth = module_option(options[:auth]) || ProjectModule.module_name(igniter, "Auth")
      {igniter, repo} = repo(igniter, options[:repo])
      {already_installed?, igniter} = ProjectModule.module_exists(igniter, auth)

      cond do
        is_nil(repo) ->
          Igniter.add_issue(
            igniter,
            "authmk needs an Ecto repo. Add one, then run `mix authmk.install` again."
          )

        already_installed? ->
          Igniter.add_notice(
            igniter,
            "#{inspect(auth)} already exists, so authmk is installed. Nothing to do."
          )

        true ->
          igniter
          |> create_auth_module(app, auth, repo)
          |> ProjectApplication.add_new_child(auth, after: [repo])
          |> configure(app, auth)
          |> mount(auth)
          |> Igniter.add_task("authmk.gen.migration")
          |> Igniter.add_notice(next_steps(auth))
      end
    end

    defp module_option(nil), do: nil
    defp module_option(name), do: ProjectModule.parse(name)

    defp repo(igniter, nil), do: IgniterEcto.select_repo(igniter)
    defp repo(igniter, name), do: {igniter, ProjectModule.parse(name)}

    defp create_auth_module(igniter, app, auth, repo) do
      mailer = ProjectModule.module_name(igniter, "Mailer")
      {has_mailer?, igniter} = ProjectModule.module_exists(igniter, mailer)
      emails = if has_mailer?, do: email_callbacks(app, mailer), else: no_mailer_note()

      ProjectModule.create_module(igniter, auth, """
      use Authmk,
        otp_app: #{inspect(app)},
        repo: #{inspect(repo)},
        plugins: [Authmk.Plugins.EmailPassword]

      #{emails}
      """)
    end

    defp email_callbacks(app, mailer) do
      """
      import Swoosh.Email

      @impl Authmk
      def send_verification_email(%{user: user, url: url}, _ctx) do
        deliver(user.email, "Verify your email", "Open this link to verify your email:\\n\\n\#{url}")
      end

      @impl Authmk
      def send_reset_password(%{user: user, url: url}, _ctx) do
        deliver(user.email, "Reset your password", "Open this link to reset your password:\\n\\n\#{url}")
      end

      defp deliver(to, subject, body) do
        new()
        |> to(to)
        |> from({#{inspect(Macro.camelize(Atom.to_string(app)))}, "no-reply@example.com"})
        |> subject(subject)
        |> text_body(body)
        |> #{inspect(mailer)}.deliver()
      end
      """
    end

    defp no_mailer_note do
      """
      # Implement send_verification_email/2 and send_reset_password/2 to send
      # authmk's emails. Until then, authmk logs a warning instead.
      """
    end

    defp configure(igniter, app, auth) do
      igniter
      |> ProjectConfig.configure_new(
        "config.exs",
        app,
        [auth, :base_url],
        "http://localhost:4000"
      )
      |> ProjectConfig.configure_new("dev.exs", app, [auth, :secret], secret())
      |> ProjectConfig.configure_new("test.exs", app, [auth, :secret], secret())
      |> ProjectConfig.configure_new("test.exs", app, [auth, :background], :inline)
      |> ProjectConfig.configure_new("test.exs", app, [auth, :rate_limit], enabled: false)
      |> ProjectConfig.configure_new("test.exs", :argon2_elixir, [:t_cost], 1)
      |> ProjectConfig.configure_new("test.exs", :argon2_elixir, [:m_cost], 8)
      |> ProjectConfig.configure_runtime_env(
        :prod,
        app,
        [auth, :base_url],
        {:code, Sourceror.parse_string!(~s|System.fetch_env!("AUTHMK_BASE_URL")|)}
      )
    end

    defp mount(igniter, auth) do
      {igniter, router} = IgniterPhoenix.select_router(igniter)

      if router,
        do: mount_phoenix(igniter, router, auth),
        else: mount_plug_router(igniter, auth)
    end

    defp mount_phoenix(igniter, router, auth) do
      igniter =
        IgniterPhoenix.add_scope(igniter, "/", "forward \"/auth\", #{inspect(auth)}",
          router: router,
          placement: :before
        )

      case IgniterPhoenix.has_pipeline(igniter, router, :browser) do
        {igniter, true} ->
          plug = "plug Authmk.Plug.FetchSession, auth: #{inspect(auth)}"
          IgniterPhoenix.append_to_pipeline(igniter, :browser, plug, router: router)

        {igniter, false} ->
          igniter
      end
    end

    defp mount_plug_router(igniter, auth) do
      {igniter, routers} =
        ProjectModule.find_all_matching_modules(igniter, fn _module, zipper ->
          match?({:ok, _}, CodeModule.move_to_use(zipper, Plug.Router))
        end)

      case routers do
        [router] ->
          ProjectModule.find_and_update_module!(igniter, router, &add_forward(&1, auth))

        _none_or_several ->
          Igniter.add_notice(
            igniter,
            "Mount authmk in your router: forward \"/auth\", to: #{inspect(auth)}"
          )
      end
    end

    # Right after `plug :dispatch`, so it is the first route.
    defp add_forward(zipper, auth) do
      dispatch =
        CodeFunction.move_to_function_call(zipper, :plug, 1, fn call ->
          CodeFunction.argument_equals?(call, 0, :dispatch)
        end)

      case dispatch do
        {:ok, zipper} ->
          {:ok,
           CodeCommon.add_code(zipper, "forward \"/auth\", to: #{inspect(auth)}",
             placement: :after
           )}

        :error ->
          {:warning, "Mount authmk in your router: forward \"/auth\", to: #{inspect(auth)}"}
      end
    end

    defp secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    defp next_steps(auth) do
      """
      authmk is installed as #{inspect(auth)}.

        * Run `mix ecto.migrate`.
        * In production, set AUTHMK_SECRET (`mix authmk.gen.secret`) and AUTHMK_BASE_URL.
        * Clients sign up with POST /auth/sign-up/email. See Authmk.Plugins.EmailPassword.
      """
    end
  end
end
