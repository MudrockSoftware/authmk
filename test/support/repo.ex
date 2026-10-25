defmodule Authmk.Test.Repo do
  @moduledoc false
  # Repo for emulation tests. Every test starts its own instance (a dynamic
  # repo) on a new database. The adapter follows AUTHMK_TEST_DB; MariaDB uses
  # the MySQL adapter.

  @adapter (case Application.compile_env(:authmk, :test_db, "sqlite") do
              "postgres" -> Ecto.Adapters.Postgres
              db when db in ["mysql", "mariadb"] -> Ecto.Adapters.MyXQL
              "sqlite" -> Ecto.Adapters.SQLite3
            end)

  use Ecto.Repo, otp_app: :authmk, adapter: @adapter
end
