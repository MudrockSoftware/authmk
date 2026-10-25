defmodule Authmk.Test.Repo do
  @moduledoc false
  # SQLite repo for emulation tests. Every test starts its own instance
  # (a dynamic repo) on a new database file.
  use Ecto.Repo, otp_app: :authmk, adapter: Ecto.Adapters.SQLite3
end
