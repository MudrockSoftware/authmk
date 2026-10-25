defmodule Authmk.ConfigTest.ValidAuth do
  use Authmk, otp_app: :authmk, repo: Authmk.Test.Repo, base_url: "http://localhost:4000"
end

defmodule Authmk.ConfigTest.NoBaseUrl do
  use Authmk, otp_app: :authmk, repo: Authmk.Test.Repo
end

defmodule Authmk.ConfigTest.ConflictingPlugin do
  @moduledoc false
  use Authmk.Plugin

  @impl true
  def schema(_opts), do: %{user: [fields: [nickname: [type: :text]]]}
end

defmodule Authmk.ConfigTest.NeedsGreeting do
  @moduledoc false
  use Authmk.Plugin

  @impl true
  def depends_on, do: [Authmk.Test.GreetingPlugin]
end

defmodule Authmk.ConfigTest do
  use ExUnit.Case, async: true

  alias Authmk.ConfigTest.{NeedsGreeting, ValidAuth}

  describe "compile-time errors point at the problem" do
    test "schema config for an unknown model" do
      assert_compile_error(~r/unknown model :profile/, schema: [profile: [table: "profiles"]])
    end

    test "renaming a field that doesn't exist" do
      assert_compile_error(~r/renames unknown field user.nick/,
        schema: [user: [fields: [nick: [source: :n]]]]
      )
    end

    test "renames may only change the column" do
      assert_compile_error(~r/may only set :source/,
        schema: [user: [fields: [name: [type: :text]]]]
      )
    end

    test "an additional field that already exists" do
      assert_compile_error(~r/already exists/,
        schema: [user: [additional_fields: [email: [type: :string]]]]
      )
    end

    test "types outside the portable set" do
      assert_compile_error(~r/invalid field :tags/,
        schema: [user: [additional_fields: [tags: [type: {:array, :string}]]]]
      )
    end

    test "two plugins defining the same field differently" do
      assert_compile_error(~r/defines user.nickname differently/,
        plugins: [Authmk.Test.GreetingPlugin, Authmk.ConfigTest.ConflictingPlugin]
      )
    end

    test "references to unknown models" do
      assert_compile_error(~r/references unknown model :team/,
        schema: [user: [additional_fields: [team_id: [references: :team]]]]
      )
    end
  end

  describe "startup errors" do
    test "a missing base_url" do
      assert {:error, {{%NimbleOptions.ValidationError{} = error, _stack}, _child}} =
               start_supervised(Authmk.ConfigTest.NoBaseUrl)

      assert Exception.message(error) =~ "base_url"
    end

    test "compile-time options can't come from app config" do
      Application.put_env(:authmk, ValidAuth, repo: Other.Repo)
      on_exit(fn -> Application.delete_env(:authmk, ValidAuth) end)

      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised(ValidAuth)

      assert message =~ "[:repo] can only be set in `use Authmk`"
    end

    test "a plugin whose dependency isn't enabled" do
      defmodule NeedsGreetingAuth do
        use Authmk,
          otp_app: :authmk,
          repo: Authmk.Test.Repo,
          plugins: [NeedsGreeting],
          base_url: "http://localhost:4000"
      end

      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised(NeedsGreetingAuth)

      assert message =~ "needs Authmk.Test.GreetingPlugin to be enabled"
    end
  end

  test "using a module that isn't started explains how to fix it" do
    assert_raise ArgumentError, ~r/is not started. Add it to your supervision tree/, fn ->
      ValidAuth.config()
    end
  end

  test "runtime options come from app config and override use options" do
    Application.put_env(:authmk, ValidAuth,
      base_url: "https://example.com",
      session: [expires_in: 60]
    )

    on_exit(fn -> Application.delete_env(:authmk, ValidAuth) end)

    start_supervised!(ValidAuth)
    config = ValidAuth.config()

    assert config.base_url == "https://example.com"
    assert config.session[:expires_in] == 60
    assert config.session[:update_age] == 86_400
  end

  defp assert_compile_error(message, opts) do
    module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")
    opts = Keyword.merge([otp_app: :authmk, repo: Authmk.Test.Repo], opts)

    assert_raise ArgumentError, message, fn ->
      Code.eval_quoted(
        quote do
          defmodule unquote(module) do
            use Authmk, unquote(opts)
          end
        end
      )
    end
  end
end
