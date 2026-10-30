defmodule Mix.Tasks.Authmk.CreateAdmin do
  @shortdoc "Creates an admin user, or makes a user an admin"

  @moduledoc """
  Creates an admin (`Authmk.Plugins.Admin`), or gives an existing user the
  admin role.

      mix authmk.create_admin ada@example.com --name "Ada Lovelace"
      AUTHMK_ADMIN_PASSWORD=... mix authmk.create_admin ada@example.com

  The password comes from `AUTHMK_ADMIN_PASSWORD`, never from the command
  line, where it would stay in the shell's history. Without it, the admin
  has no password and sets one with "forgot password" (or signs in another
  way, like a magic link). Existing users keep theirs.

  ## Options

    * `--name NAME` - the new admin's name (default: the email's local part)
    * `--auth MyApp.Auth` - the auth module, when the app has several

  It starts your app, so it runs against the database your config points
  at. In a release, call `Authmk.Plugins.Admin.create_admin/2` instead.
  """

  use Mix.Task

  alias Authmk.Plugins.Admin

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [name: :string, auth: :string])

    email =
      case rest do
        [email] -> email
        _other -> Mix.raise("Usage: mix authmk.create_admin EMAIL [--name NAME]")
      end

    Mix.Task.run("app.start", [])
    auth = Mix.Authmk.auth_module(opts[:auth])
    attrs = %{email: email, name: opts[:name], password: System.get_env("AUTHMK_ADMIN_PASSWORD")}

    case Admin.create_admin(auth, attrs) do
      {:ok, user, :created} ->
        Mix.shell().info("Created admin #{user.email}.")
        if is_nil(attrs.password), do: Mix.shell().info(no_password())

      {:ok, user, :promoted} ->
        Mix.shell().info("#{user.email} is an admin now (role: #{user.role}).")

      {:ok, user, :unchanged} ->
        Mix.shell().info("#{user.email} is already an admin.")

      {:error, error} ->
        Mix.raise("Couldn't create the admin: #{error.message}")
    end
  end

  defp no_password,
    do: "No password set (AUTHMK_ADMIN_PASSWORD was empty): set one with a password reset."
end
