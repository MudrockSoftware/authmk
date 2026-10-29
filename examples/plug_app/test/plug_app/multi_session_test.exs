defmodule PlugApp.MultiSessionTest do
  # SQLite takes one writer at a time: tests that sign up run one by one.
  use PlugApp.ConnCase, async: false

  test "two accounts on one device, and switching between them" do
    for email <- ["ada@example.com", "grace@example.com"],
        do:
          post_json("/auth/sign-up/email", %{email: email, password: "correct horse", name: email})

    device =
      cookies(
        post_json("/auth/sign-in/email", %{email: "ada@example.com", password: "correct horse"})
      )

    device =
      Map.merge(
        device,
        cookies(
          post_json(
            "/auth/sign-in/email",
            %{email: "grace@example.com", password: "correct horse"},
            device
          )
        )
      )

    assert json(get_path("/me", device))["email"] == "grace@example.com"

    sessions = json(get_path("/auth/multi-session/list-device-sessions", device))
    ada = Enum.find(sessions, &(&1["user"]["email"] == "ada@example.com"))["session"]["id"]

    device =
      Map.merge(
        device,
        cookies(post_json("/auth/multi-session/set-active", %{session_id: ada}, device))
      )

    assert json(get_path("/me", device))["email"] == "ada@example.com"
  end
end
