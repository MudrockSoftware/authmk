# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     PhoenixApp.Repo.insert!(%PhoenixApp.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# An admin to try the dashboard at /admin/auth (development only):
# admin@example.com / "correct horse battery".
# (In other environments: `mix authmk.create_admin EMAIL`.)
if Mix.env() == :dev do
  {:ok, _admin, status} =
    Authmk.Plugins.Admin.create_admin(PhoenixApp.Auth, %{
      email: "admin@example.com",
      name: "Admin",
      password: "correct horse battery"
    })

  if status == :created,
    do: IO.puts("Created admin@example.com with the password \"correct horse battery\"")
end
