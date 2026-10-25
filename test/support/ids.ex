defmodule Authmk.Test.Ids do
  @moduledoc false
  # A custom id generator, like an app's own prefixed ids.
  def generate, do: "id_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
