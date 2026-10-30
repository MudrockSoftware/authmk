defmodule Authmk.LicenseTest do
  # Reads and sets an environment variable.
  use ExUnit.Case, async: false

  alias Authmk.License

  @valid "authmk_" <> String.duplicate("a1", 12)

  test "development and tests need no key" do
    assert License.check(env: :dev, key: nil) == :ok
    assert License.check(env: :test, key: nil) == :ok
    assert License.check() == :ok
  end

  test "elsewhere a key is needed, of the right shape" do
    assert License.check(env: :prod, key: nil) == {:error, :missing}
    assert License.check(env: :prod, key: "") == {:error, :missing}
    assert License.check(env: :prod, key: "free-please") == {:error, :invalid}
    assert License.check(env: :prod, key: "authmk_short") == {:error, :invalid}
    assert License.check(env: :staging, key: @valid) == :ok
    assert License.check(env: :prod, key: " #{@valid}\n") == :ok

    assert License.explain(:missing) =~ "AUTHMK_LICENCE_KEY"
  end

  test "the key comes from AUTHMK_LICENCE_KEY" do
    previous = System.get_env("AUTHMK_LICENCE_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("AUTHMK_LICENCE_KEY", previous),
        else: System.delete_env("AUTHMK_LICENCE_KEY")
    end)

    System.delete_env("AUTHMK_LICENCE_KEY")
    assert License.check(env: :prod) == {:error, :missing}

    System.put_env("AUTHMK_LICENCE_KEY", @valid)
    assert License.check(env: :prod) == :ok
    assert License.env_var() == "AUTHMK_LICENCE_KEY"
  end
end
