defmodule Authmk.Plugins.APIKey.Options do
  @moduledoc false

  @configuration [
    prefix: [type: :string, doc: "Starts every key, like `\"sk_live_\"`."],
    key_length: [type: :pos_integer, default: 64, doc: "Random characters after the prefix."],
    start_length: [
      type: :non_neg_integer,
      default: 6,
      doc: "Characters of the key kept in clear (`start`), to tell keys apart."
    ],
    default_expires_in: [type: :pos_integer, doc: "Seconds. Keys don't expire without it."],
    min_expires_in: [type: :pos_integer, default: 86_400],
    max_expires_in: [type: :pos_integer, default: 365 * 86_400],
    disable_custom_expires_in: [
      type: :boolean,
      default: false,
      doc: "Clients can't choose an expiry."
    ],
    rate_limit: [
      type: :keyword_list,
      default: [],
      keys: [
        enabled: [type: :boolean, default: true],
        time_window: [type: :pos_integer, default: 86_400, doc: "Seconds."],
        max_requests: [type: :pos_integer, default: 10]
      ]
    ],
    default_permissions: [
      type: {:map, :string, {:list, :string}},
      default: %{},
      doc: ~s(Permissions of new keys, like `%{"files" => ["read"]}`.)
    ],
    require_name: [type: :boolean, default: false],
    enable_metadata: [type: :boolean, default: false, doc: "Clients may store metadata on keys."]
  ]

  @schema NimbleOptions.new!(
            configurations: [
              type: :keyword_list,
              default: [default: []],
              doc:
                "Key configurations by id, chosen with `config_id` (`default` otherwise). Each takes: #{Enum.map_join(Keyword.keys(@configuration), ", ", &"`#{&1}`")}."
            ],
            headers: [
              type: {:list, :string},
              default: ["x-api-key"],
              doc: "Headers that carry keys."
            ],
            enable_sessions: [
              type: :boolean,
              default: false,
              doc:
                "Requests with a user's key in a header are signed in as that user (for the auth router and `Authmk.Plug.FetchSession`)."
            ],
            storage: [
              type: {:in, [:database, :secondary_storage, :both]},
              default: :database,
              doc:
                "Where keys live: the database, secondary storage, or the database with secondary storage as a cache."
            ],
            custom_key_generator: [
              type: {:fun, 1},
              doc:
                "Makes keys: called with `%{prefix: prefix, length: length}`. Must be unguessable."
            ],
            custom_key_validator: [
              type: {:fun, 2},
              doc:
                "An extra check on keys before they're looked up: called with the key and the context, returns a boolean."
            ]
          )

  def schema, do: @schema

  @doc false
  def configuration(opts, id) do
    case Keyword.fetch(opts[:configurations], String.to_existing_atom(id)) do
      {:ok, config} -> {:ok, NimbleOptions.validate!(config, @configuration)}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc false
  def validate_configurations!(configurations) do
    Enum.each(configurations, fn {_id, config} ->
      NimbleOptions.validate!(config, @configuration)
    end)
  end
end
