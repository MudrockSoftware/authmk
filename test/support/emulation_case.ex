defmodule Authmk.EmulationCase do
  @moduledoc false
  # Case template for emulation tests. Each test gets a new SQLite database,
  # migrated with authmk's generated migration, and a started auth module.
  #
  #     use Authmk.EmulationCase, async: true
  #     @moduletag auth: MyTestAuth

  use ExUnit.CaseTemplate

  alias Authmk.Test.{Browser, Database, Repo}

  using do
    quote do
      import Authmk.Test.Browser
      import Authmk.EmulationCase
    end
  end

  setup %{auth: auth} do
    database = Database.create!()
    on_exit(fn -> Database.delete!(database) end)

    repo = start_supervised!(Database.repo_child_spec(database))
    Repo.put_dynamic_repo(repo)
    Database.migrate!(auth, repo)
    start_supervised!(auth)

    %{browser: Browser.new(auth), repo: repo}
  end

  @doc "Waits for an email message the test auth module sent to the test process."
  defmacro assert_email(kind, timeout \\ 100) do
    quote do
      assert_receive {:email, unquote(kind), link}, unquote(timeout)
      link
    end
  end

  @doc "Signs up and returns the signed-in browser and the user JSON."
  def sign_up(browser, attrs \\ %{}) do
    attrs = Map.merge(%{email: "ada@example.com", password: "correct horse", name: "Ada"}, attrs)
    {browser, conn} = Browser.post(browser, "/sign-up/email", attrs)
    200 = conn.status
    {browser, Browser.json(conn)["user"]}
  end

  @doc "The token query param of a URL."
  def token_from(url), do: URI.decode_query(URI.parse(url).query)["token"]
end
