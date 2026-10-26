defmodule Authmk.AccessControlTest do
  use ExUnit.Case, async: true

  defmodule Permissions do
    use Authmk.AccessControl,
      statements: [project: [:create, :update, :delete], billing: [:read, :update]],
      roles: [
        owner: [project: [:create, :update, :delete], billing: [:read, :update]],
        member: [project: [:create, :update]],
        accountant: %{"billing" => ["read"]},
        viewer: []
      ]
  end

  test "roles grant their actions, and nothing else" do
    assert Permissions.has_permission?("member", %{project: [:create, :update]})
    refute Permissions.has_permission?("member", %{project: [:delete]})
    refute Permissions.has_permission?("viewer", %{project: [:create]})
    assert Permissions.has_permission?(:owner, project: [:delete], billing: [:update])
  end

  test "several roles grant together, from a list or a stored string" do
    refute Permissions.has_permission?("member", %{project: [:create], billing: [:read]})

    assert Permissions.has_permission?("member, accountant", %{
             project: [:create],
             billing: [:read]
           })

    assert Permissions.has_permission?([:member, "accountant"], %{"billing" => ["read"]})
  end

  test "with :or, one granted action is enough" do
    assert Permissions.has_permission?("member", %{project: [:delete, :create]}, :or)
    refute Permissions.has_permission?("member", %{project: [:delete]}, :or)
  end

  test "unknown roles, resources and actions grant nothing; asking for nothing is no" do
    refute Permissions.has_permission?("superuser", %{project: [:create]})
    refute Permissions.has_permission?("owner", %{servers: [:reboot]})
    refute Permissions.has_permission?("owner", %{project: [:archive]})
    refute Permissions.has_permission?("owner", %{})
    refute Permissions.has_permission?(nil, %{project: [:create]})
  end

  test "roles can't grant what no statement has" do
    assert_raise ArgumentError, ~r/role member grants unknown project actions: archive/, fn ->
      Authmk.AccessControl.new!([project: [:create]], member: [project: [:create, :archive]])
    end

    assert_raise ArgumentError, ~r/unknown resource servers/, fn ->
      Authmk.AccessControl.new!([project: [:create]], admin: [servers: [:reboot]])
    end
  end

  test "role names, and checking a role string" do
    ac = Permissions.access_control()
    assert Permissions.role_names() == ["accountant", "member", "owner", "viewer"]
    assert Authmk.AccessControl.valid_roles?(ac, "owner,member")
    refute Authmk.AccessControl.valid_roles?(ac, "owner,root")
    refute Authmk.AccessControl.valid_roles?(ac, "")
  end
end
