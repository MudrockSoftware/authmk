defmodule Authmk.Plugins.Anonymous.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            email_domain: [
              type: :string,
              doc: "Domain of generated emails. Defaults to the base URL's host."
            ],
            generate_email: [
              type: {:fun, 0},
              doc: "Makes an anonymous user's email, instead of `temp-<random>@<email_domain>`."
            ],
            generate_name: [
              type: {:fun, 0},
              doc: ~s(Makes an anonymous user's name, instead of "Anonymous".)
            ],
            on_link_account: [
              type: {:fun, 2},
              doc:
                "Called with `%{anonymous_user: user, new_user: user}` and the context when an anonymous user signs in for real: move their data here."
            ],
            disable_delete_anonymous_user: [
              type: :boolean,
              default: false,
              doc: "Keep the anonymous user after linking (by default it is deleted)."
            ]
          )

  def schema, do: @schema
end
