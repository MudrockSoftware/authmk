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

// The rest of the README's "Getting started", shortened to three steps.
const steps = [
  {
    title: "Add the dependency",
    lang: "elixir",
    code: `# mix.exs
{:authmk, "~> 1.2"}`,
  },
  {
    title: "Create the tables",
    lang: "sh",
    code: `# put the output in AUTHMK_SECRET
mix authmk.gen.secret

mix authmk.gen.migration
mix ecto.migrate`,
  },
  {
    title: "Start it and mount it",
    lang: "elixir",
    code: `# application.ex
children = [MyApp.Repo, MyApp.Auth]

# router.ex
forward "/auth", MyApp.Auth
plug Authmk.Plug.FetchSession, auth: MyApp.Auth`,
  },
];

export function load() {
  return {
    authModule: highlight(authModule, "elixir"),
    steps: steps.map((step) => ({ title: step.title, html: highlight(step.code, step.lang) })),
  };
}
