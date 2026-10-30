defmodule Authmk.Fuzz.DashboardAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false],
    schema: [user: [additional_fields: [seats: [type: :integer], joined: [type: :datetime]]]],
    plugins: [
      Authmk.Plugins.EmailPassword,
      Authmk.Plugins.Admin,
      Authmk.Plugins.AuditLog,
      Authmk.Plugins.Organization,
      Authmk.Dashboard.Branding
    ]
end

defmodule Authmk.DashboardFuzzTest do
  # What admins send the dashboard (dates, fields, branding, paths) and
  # what it writes to CSV: never a crash, never a formula.
  use Authmk.EmulationCase, async: true
  use ExUnitProperties

  import Authmk.Test.DashboardHelpers

  alias Authmk.Dashboard.CSV
  alias Authmk.Dashboard.Data.Analytics
  alias Authmk.Fuzz.DashboardAuth, as: Auth
  alias Authmk.Testing

  @moduletag :fuzz
  @moduletag auth: Auth

  setup do
    %{admin: Testing.create_user(Auth, email: "admin@example.com", role: "admin")}
  end

  defp json_value do
    leaf = one_of([string(:printable), integer(), boolean(), constant(nil), float()])

    tree(leaf, fn child ->
      one_of([list_of(child, max_length: 3), map_of(string(:alphanumeric), child, max_length: 3)])
    end)
  end

  property "date ranges are a range or a message" do
    check all(
            from <- one_of([constant(nil), string(:printable)]),
            to <- one_of([constant(nil), string(:printable)])
          ) do
      assert match?({:ok, %Date{}, %Date{}}, Analytics.range(from, to)) or
               match?({:error, message} when is_binary(message), Analytics.range(from, to))
    end
  end

  property "CSV values never start like a formula" do
    check all(values <- list_of(string(:printable), min_length: 1, max_length: 5)) do
      csv = values |> then(&CSV.encode(["header"], [&1])) |> IO.iodata_to_binary()

      for value <- values, String.starts_with?(value, ["=", "+", "-", "@"]) do
        refute csv =~ ~r/(^|,|")#{Regex.escape(value)}/m
      end
    end
  end

  property "random field values and branding are saved or refused, never a crash", %{
    admin: admin
  } do
    ada = Testing.create_user(Auth, email: "ada@example.com")

    check all(
            fields <-
              map_of(member_of(["seats", "joined", "name", "x"]), json_value(), max_length: 3),
            branding <-
              map_of(member_of(["app_name", "primary_color", "logo", "x"]), json_value(),
                max_length: 3
              )
          ) do
      conn = api(Auth, :post, "users/#{ada.id}/update", admin, body: %{fields: fields})
      assert conn.status in [200, 400, 422]

      conn = api(Auth, :post, "branding", admin, body: branding)
      assert conn.status in [200, 400]
    end
  end

  property "any path under the API gets a JSON answer", %{admin: admin} do
    check all(
            segments <- list_of(string(:alphanumeric, min_length: 1), max_length: 4),
            method <- member_of([:get, :post])
          ) do
      conn = api(Auth, method, Enum.join(segments, "/"), admin, body: %{})
      assert conn.status in [200, 400, 403, 404, 422]
      assert {:ok, _json} = JSON.decode(conn.resp_body)
    end
  end
end
