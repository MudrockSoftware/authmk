defmodule Authmk.SchemaConfigTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    table_naming: :singular,
    table_prefix: "auth_",
    primary_key: :id,
    schema: [
      user: [
        module: Authmk.SchemaConfigTest.Person,
        table: "people",
        fields: [name: [source: :full_name]]
      ]
    ],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.SchemaConfigTest.Person do
  @moduledoc false
  # A user schema the app owns, with its own extra code.
  use Ecto.Schema
  use Authmk.Schema, auth: Authmk.SchemaConfigTest.Auth, model: :user

  schema "people" do
    authmk_fields()
    field(:greeting, :string, virtual: true)
    timestamps()
  end

  def greet(person), do: %{person | greeting: "Hi #{person.name}"}
end

defmodule Authmk.SchemaConfigTest do
  use Authmk.EmulationCase, async: true

  alias Authmk.SchemaConfigTest.Person
  alias Authmk.Test.{Database, Repo}

  @moduletag auth: Authmk.SchemaConfigTest.Auth

  test "tables follow naming, prefix and explicit names" do
    tables = Database.tables()

    assert "people" in tables
    assert "auth_session" in tables
    assert "auth_account" in tables
    assert "auth_verification" in tables
  end

  test "a renamed field uses its column", %{browser: browser} do
    {_browser, user} = sign_up(browser, %{name: "Ada"})
    assert user["name"] == "Ada"

    assert [["Ada"]] = Repo.query!("SELECT full_name FROM people").rows
  end

  test "the app's own module is used for users, with integer ids", %{browser: browser} do
    {_browser, user} = sign_up(browser)
    assert is_integer(user["id"])

    person = Repo.get!(Person, user["id"])
    assert Person.greet(person).greeting == "Hi Ada"
  end

  test "sessions belong to the app's user module", %{browser: browser} do
    {browser, _user} = sign_up(browser)
    {_browser, _conn} = get(browser, "/get-session")

    session = Repo.one!(Authmk.SchemaConfigTest.Auth.Session) |> Repo.preload(:user)
    assert %Person{email: "ada@example.com"} = session.user
  end
end
