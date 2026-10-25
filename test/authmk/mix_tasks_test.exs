defmodule Authmk.MixTasksTest do
  # Mix tasks print through the global Mix shell: not async.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Authmk.{Gen, Info}

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    dir = Path.join(System.tmp_dir!(), "authmk_tasks_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{snapshot: Path.join(dir, "snapshot.json")}
  end

  test "gen.secret prints a new random secret each time" do
    Gen.Secret.run([])
    Gen.Secret.run([])

    assert_received {:mix_shell, :info, [first]}
    assert_received {:mix_shell, :info, [second]}
    assert byte_size(first) >= 32 and first =~ ~r/\A[A-Za-z0-9_-]+\z/
    assert first != second
  end

  test "info reports the setup, and fails while migrations are missing", %{snapshot: snapshot} do
    args = ["--auth", "Authmk.MigrationTest.Base", "--snapshot-path", snapshot]

    assert_raise Mix.Error, ~r/checks failed/, fn -> Info.run(args) end
    output = shell_output()
    assert output =~ "Auth module:  Authmk.MigrationTest.Base"
    assert output =~ "Plugins:      Authmk.Plugins.EmailPassword"
    assert output =~ "Run `mix authmk.gen.migration`"

    Gen.Migration.run(args ++ ["--baseline"])
    _baseline_message = shell_output()

    Info.run(args)
    output = shell_output()
    assert output =~ "Migrations:   up to date"
    assert output =~ "Config:       ok"
    assert output =~ "POST /sign-in/email"
  end

  # Everything the task printed so far, as one string.
  defp shell_output(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> shell_output([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
