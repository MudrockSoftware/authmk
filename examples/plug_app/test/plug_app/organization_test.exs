defmodule PlugApp.OrganizationTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  import Swoosh.TestAssertions

  defp sign_up(email) do
    conn =
      post_json("/auth/sign-up/email", %{email: email, password: "correct horse", name: "User"})

    cookies(conn)
  end

  test "create an organization, invite someone by email, and they join" do
    owner = sign_up("ada@example.com")
    conn = post_json("/auth/organization/create", %{name: "Acme", slug: "acme"}, owner)
    owner = Map.merge(owner, cookies(conn))
    assert json(conn)["slug"] == "acme"

    post_json(
      "/auth/organization/invite-member",
      %{email: "grace@example.com", role: "member"},
      owner
    )

    assert_email_sent(fn email ->
      assert email.subject == "Join Acme"
      [_, id] = Regex.run(~r/invitation id is ([\w-]+)/, email.text_body)
      send(self(), {:invitation, id})
    end)

    assert_received {:invitation, id}
    grace = sign_up("grace@example.com")
    conn = post_json("/auth/organization/accept-invitation", %{invitation_id: id}, grace)
    assert json(conn)["member"]["role"] == "member"

    conn = get_path("/auth/organization/list", Map.merge(grace, cookies(conn)))
    assert [%{"name" => "Acme"}] = json(conn)
  end
end
