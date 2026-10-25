defmodule Mix.Tasks.Authmk.Gen.Secret do
  @shortdoc "Generates a random secret for AUTHMK_SECRET"

  @moduledoc """
  Prints a random 256-bit secret, for the `AUTHMK_SECRET` environment
  variable:

      mix authmk.gen.secret
  """

  use Mix.Task

  @impl true
  def run(_args) do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Mix.shell().info(secret)
  end
end
