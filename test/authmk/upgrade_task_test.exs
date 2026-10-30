defmodule Authmk.UpgradeTaskTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "an upgrade generates the migration and says what to check" do
    igniter =
      test_project(app_name: :my_app)
      |> Igniter.compose_task("authmk.upgrade", ["0.1.0", "0.2.0"])

    assert {"authmk.gen.migration", []} in igniter.tasks
    assert Enum.any?(igniter.notices, &(&1 =~ "authmk upgraded from 0.1.0 to 0.2.0"))
    assert igniter.issues == []
  end

  test "nothing to do going sideways or back; bad versions are refused" do
    same = test_project() |> Igniter.compose_task("authmk.upgrade", ["0.2.0", "0.2.0"])
    assert same.tasks == []
    assert Enum.any?(same.notices, &(&1 =~ "nothing to upgrade"))

    bad = test_project() |> Igniter.compose_task("authmk.upgrade", ["latest", "0.2.0"])
    assert [issue] = bad.issues
    assert issue =~ "Give versions"
  end
end
