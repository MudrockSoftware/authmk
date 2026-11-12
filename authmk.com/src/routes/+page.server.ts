import { highlight } from "#lib/server/highlight.ts";

// The auth module at the top of the home page, from the README.
const authModule = `defmodule MyApp.Auth do
  use Authmk,
    otp_app: :my_app,
    repo: MyApp.Repo,
    plugins: [
      Authmk.Plugins.EmailPassword,
      {Authmk.Plugins.TwoFactor, issuer: "My App"},
      Authmk.Plugins.Organization
    ]

  @impl Authmk
  def send_reset_password(%{user: user, url: url}, _ctx) do
    MyApp.Mailer.deliver_reset_link(user.email, url)
  end
end`;

// The rest of the README's "Getting started", as steps.
const steps = [
  {
    title: "Add the dependency",
    body: "Then define your auth module, as above, with the plugins you need.",
    lang: "elixir",
    code: `# mix.exs
{:authmk, "~> 1.2"}`,
  },
  {
    title: "Set a secret and generate the migration",
    body: "authmk compares its schema with a snapshot in your repository and writes a normal Ecto migration.",
    lang: "sh",
    code: `mix authmk.gen.secret       # put the output in AUTHMK_SECRET
mix authmk.gen.migration
mix ecto.migrate`,
  },
  {
    title: "Start it, mount it, and load the signed-in user",
    body: "Works in Phoenix routers and in Plug.Router alike.",
    lang: "elixir",
    code: `# application.ex
children = [MyApp.Repo, MyApp.Auth, ...]

# router.ex
forward "/auth", MyApp.Auth

# your pipelines
plug Authmk.Plug.FetchSession, auth: MyApp.Auth   # assigns :current_user
plug Authmk.Plug.RequireUser, redirect_to: "/sign-in"`,
  },
];

const plugin = `defmodule MyApp.Auth do
  use Authmk,
    otp_app: :my_app,
    repo: MyApp.Repo,
    plugins: [{Authmk.Plugins.EmailPassword, require_email_verification: true}]

  # Your auth module gets the same hooks as plugins.
  @impl Authmk
  def before_endpoint(:sign_up_email, ctx) do
    if String.ends_with?(ctx.raw_params["email"], "@example.com"),
      do: {:cont, ctx},
      else: {:halt, Authmk.Error.new(:forbidden)}
  end

  def before_endpoint(_endpoint, ctx), do: {:cont, ctx}
end`;

export function load() {
  return {
    authModule: highlight(authModule, "elixir"),
    steps: steps.map((step) => ({ title: step.title, body: step.body, html: highlight(step.code, step.lang) })),
    plugin: highlight(plugin, "elixir"),
  };
}
