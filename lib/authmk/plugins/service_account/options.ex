defmodule Authmk.Plugins.ServiceAccount.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            access_control: [
              type: :atom,
              doc:
                "The `Authmk.AccessControl` module for roles of service accounts owned by users. Organization service accounts use the organization's roles."
            ],
            headers: [
              type: {:list, :string},
              default: ["x-api-key"],
              doc: "Headers that carry keys."
            ]
          )

  def schema, do: @schema
end
