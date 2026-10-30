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
if Mix.env() == :dev and
     is_nil(Authmk.Testing.get_user_by(PhoenixApp.Auth, email: "admin@example.com")) do
  Authmk.Testing.create_user(PhoenixApp.Auth,
    email: "admin@example.com",
    name: "Admin",
    password: "correct horse battery",
    role: "admin"
  )

  IO.puts("Created admin@example.com with the password \"correct horse battery\"")
end
