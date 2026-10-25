defmodule PhoenixAppWeb.PageControllerTest do
  use PhoenixAppWeb.ConnCase

  test "GET / when signed out", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "You are not signed in."
  end
end
