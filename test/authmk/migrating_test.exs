defmodule Authmk.MigratingTest do
  # Moving an app from phx.gen.auth to authmk, as guides/migrating-from-phx-gen-auth.md
  # says: its `users` table is kept (and the tables pointing at it), the
  # passwords move over and keep working, and authmk creates the rest.
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Authmk.Migration
  alias Authmk.Migration.Snapshot
  alias Authmk.Test.{Browser, Database, Repo}

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      # phx.gen.auth's ids are integers, and its passwords bcrypt.
      primary_key: :id,
      password_hasher: Authmk.Password.Bcrypt,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      plugins: [Authmk.Plugins.EmailPassword]
  end

  # What `mix phx.gen.auth Accounts User users` created, and a table of the app's.
  defmodule PhxGenAuthTables do
    use Ecto.Migration

    def change do
      create table(:users) do
        add :email, :string, null: false
        add :hashed_password, :string
        add :confirmed_at, :utc_datetime
        timestamps(type: :utc_datetime)
      end

      create unique_index(:users, [:email])

      create table(:users_tokens) do
        add :user_id, references(:users, on_delete: :delete_all), null: false
        add :token, :binary, null: false
        add :context, :string, null: false
        timestamps(type: :utc_datetime, updated_at: false)
      end

      create table(:posts) do
        add :title, :string
        add :user_id, references(:users, on_delete: :delete_all)
      end
    end
  end

  # Step 1 of the guide: authmk's user columns on the existing table.
  defmodule AddAuthmkUserColumns do
    use Ecto.Migration

    def change do
      alter table(:users) do
        add :name, :string
        add :email_verified, :boolean, null: false, default: false
        add :image, :text
      end
    end
  end

  # Step 3: names, verified emails and passwords, into authmk's shape.
  defmodule MoveUsersToAuthmk do
    use Ecto.Migration

    import Ecto.Query

    def up do
      execute(fn ->
        repo().update_all(
          from(u in "users", where: is_nil(u.name), update: [set: [name: u.email]]),
          []
        )

        # Typed: SQLite would otherwise store the text "true".
        repo().update_all(
          from(u in "users",
            where: not is_nil(u.confirmed_at),
            update: [set: [email_verified: type(^true, :boolean)]]
          ),
          []
        )

        now = DateTime.utc_now()

        accounts =
          from(u in "users",
            where: not is_nil(u.hashed_password),
            select: %{id: u.id, hash: u.hashed_password}
          )
          |> repo().all()
          |> Enum.map(fn user ->
            %{
              user_id: user.id,
              account_id: to_string(user.id),
              provider_id: "credential",
              password: user.hash,
              inserted_at: now,
              updated_at: now
            }
          end)

        repo().insert_all("accounts", accounts)
      end)
    end

    def down, do: :ok
  end

  setup do
    database = Database.create!()
    on_exit(fn -> Database.delete!(database) end)
    repo = start_supervised!(Database.repo_child_spec(database))
    Repo.put_dynamic_repo(repo)
    %{repo: repo}
  end

  defp migrate(repo, migrations) do
    Ecto.Migrator.run(Repo, migrations, :up, all: true, dynamic_repo: repo, log: false)
  end

  # Step 2: `mix authmk.gen.migration --existing users`.
  defp generated_migration do
    snapshot = Migration.adopt(Snapshot.empty(), Auth, ["users"])
    source = Migration.render(Auth, snapshot, "Authmk.MigratingTest.Generated")
    [{module, _bytecode}] = Code.compile_string(source)
    module
  end

  test "phx.gen.auth users sign in with their passwords, ids and data kept", %{repo: repo} do
    migrate(repo, [{1, PhxGenAuthTables}])

    {1, _rows} =
      Repo.insert_all(
        "users",
        [
          %{
            email: "ada@example.com",
            hashed_password: Bcrypt.hash_pwd_salt("an old password"),
            confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ]
      )

    # Read back rather than `returning:`, which MySQL doesn't have.
    ada_id = Repo.one!(from(u in "users", where: u.email == "ada@example.com", select: u.id))
    Repo.insert_all("posts", [%{title: "Notes", user_id: ada_id}])

    migrate(repo, [{2, AddAuthmkUserColumns}, {3, generated_migration()}, {4, MoveUsersToAuthmk}])
    start_supervised!(Auth)

    {browser, conn} =
      Browser.post(Browser.new(Auth), "/sign-in/email", %{
        email: "ada@example.com",
        password: "an old password"
      })

    assert conn.status == 200

    assert %{"id" => ^ada_id, "email_verified" => true, "name" => "ada@example.com"} =
             Browser.json(conn)["user"]

    {_browser, conn} = Browser.get(browser, "/get-session")
    assert Browser.json(conn)["user"]["id"] == ada_id

    # The app's own tables still point at the same users.
    assert Repo.one(from(p in "posts", select: p.user_id)) == ada_id

    # New users sign up into the same table.
    {_browser, conn} =
      Browser.post(Browser.new(Auth), "/sign-up/email", %{
        email: "grace@example.com",
        password: "a new password",
        name: "Grace"
      })

    assert conn.status == 200
    assert Repo.one(from(u in "users", select: count(u.id))) == 2

    # Nothing left for authmk to migrate.
    assert Migration.changes(Auth, Migration.current_snapshot(Auth)) == []
  end
end
