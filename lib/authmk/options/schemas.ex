defmodule Authmk.Options.Schemas do
  @moduledoc false

  @day 86_400

  @compile_schema NimbleOptions.new!(
                    otp_app: [type: :atom, required: true, doc: "Your OTP application."],
                    repo: [type: :atom, required: true, doc: "Your Ecto repo."],
                    plugins: [
                      type: {:list, {:or, [:atom, {:tuple, [:atom, :keyword_list]}]}},
                      default: [],
                      doc: "Plugins, as `Module` or `{Module, opts}`."
                    ],
                    schema: [
                      type: :keyword_list,
                      default: [],
                      doc:
                        "Per-model config: `:table`, `:module`, `:fields` (renames), `:additional_fields`."
                    ],
                    table_naming: [type: {:in, [:plural, :singular]}, default: :plural],
                    table_prefix: [type: :string, default: ""],
                    primary_key: [
                      type: Authmk.Schema.PrimaryKey.option_type(),
                      default: :binary_id,
                      doc: "Default primary key kind. See `Authmk.Schema.PrimaryKey`."
                    ]
                  )

  @runtime_schema NimbleOptions.new!(
                    base_url: [
                      type:
                        {:or,
                         [
                           :string,
                           {:keyword_list,
                            [
                              allowed_hosts: [type: {:list, :string}, required: true],
                              protocol: [type: {:in, [:auto, "http", "https"]}, default: :auto],
                              fallback: [type: :string]
                            ]}
                         ]},
                      required: true,
                      doc:
                        "Public URL of your app, like `\"https://example.com\"`, or an allow list of hosts. See `Authmk.BaseURL`."
                    ],
                    base_path: [
                      type: :string,
                      default: "/auth",
                      doc: "Where the auth router is mounted."
                    ],
                    secret: [
                      type: :string,
                      doc:
                        "At least 32 random characters. Defaults to the `AUTHMK_SECRET` environment variable."
                    ],
                    secrets: [
                      type: {:list, {:tuple, [:non_neg_integer, :string]}},
                      doc:
                        "Versioned secrets for rotation, newest first. Defaults to `AUTHMK_SECRETS`."
                    ],
                    app_name: [type: :string, default: "authmk"],
                    social_providers: [
                      type: :keyword_list,
                      default: [],
                      doc: "Social sign-in providers. See `Authmk.OAuth.Providers`."
                    ],
                    account: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        store_state: [
                          type: {:in, [:cookie, :database]},
                          default: :cookie,
                          doc:
                            "Where in-progress social sign-ins are kept. See `Authmk.OAuth.State`."
                        ],
                        encrypt_oauth_tokens: [type: :boolean, default: false],
                        update_account_on_sign_in: [type: :boolean, default: true],
                        account_linking: [
                          type: :keyword_list,
                          default: [],
                          doc: "See `Authmk.OAuth.Accounts`.",
                          keys: [
                            enabled: [type: :boolean, default: true],
                            trusted_providers: [type: {:list, :atom}, default: []],
                            allow_different_emails: [type: :boolean, default: false],
                            allow_unlinking_all: [type: :boolean, default: false],
                            require_local_email_verified: [type: :boolean, default: true]
                          ]
                        ]
                      ]
                    ],
                    errors: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        rescue: [
                          type: :boolean,
                          default: true,
                          doc:
                            "Answer crashes with a JSON `internal_error`. `false` re-raises them to your Plug or Phoenix error handling."
                        ],
                        error_url: [
                          type: :string,
                          doc:
                            "Where redirect flows send users on errors. Defaults to authmk's `/error` page."
                        ]
                      ]
                    ],
                    secondary_storage: [
                      type: {:or, [:atom, {:tuple, [:atom, :keyword_list]}]},
                      doc:
                        "`Authmk.Storage.ETS`, `{Authmk.Storage.Redis, conn: ...}` or your own `Authmk.Storage`."
                    ],
                    verification: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        store_in_database: [
                          type: :boolean,
                          default: false,
                          doc:
                            "With secondary storage, also keep verification tokens in the database."
                        ]
                      ]
                    ],
                    trusted_origins: [
                      type: {:list, :string},
                      default: [],
                      doc: "Extra origins allowed to send requests and receive redirects."
                    ],
                    disabled_paths: [
                      type: {:list, :string},
                      default: [],
                      doc: "Endpoint paths to turn off."
                    ],
                    background: [
                      type: {:in, [:task, :inline]},
                      default: :task,
                      doc: "Run emails and other side work in a supervised task, or inline."
                    ],
                    password_hasher: [type: :atom, default: Authmk.Password.Argon2],
                    find_many_limit: [type: :pos_integer, default: 100],
                    email_verification: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        send_on_sign_up: [type: :boolean, default: false],
                        send_on_sign_in: [type: :boolean, default: false],
                        auto_sign_in_after_verification: [type: :boolean, default: false],
                        expires_in: [type: :pos_integer, default: 3600]
                      ]
                    ],
                    session: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        expires_in: [type: :pos_integer, default: 7 * @day],
                        update_age: [type: :pos_integer, default: @day],
                        fresh_age: [
                          type: :non_neg_integer,
                          default: @day,
                          doc: "`0` disables the check."
                        ],
                        disable_refresh: [type: :boolean, default: false],
                        store_in_database: [
                          type: :boolean,
                          default: false,
                          doc: "With secondary storage, also keep sessions in the database."
                        ],
                        preserve_in_database: [
                          type: :boolean,
                          default: false,
                          doc:
                            "Keep revoked sessions' database rows, marked ended, instead of deleting them."
                        ],
                        defer_refresh: [
                          type: :boolean,
                          default: false,
                          doc:
                            "Keep `GET /get-session` read-only; it reports `needs_refresh` and `POST /get-session` refreshes."
                        ],
                        cookie_cache: [
                          type: :keyword_list,
                          default: [],
                          doc: "See `Authmk.CookieCache`.",
                          keys: [
                            enabled: [type: :boolean, default: false],
                            max_age: [type: :pos_integer, default: 300, doc: "Seconds."],
                            strategy: [type: {:in, [:signed, :encrypted]}, default: :signed],
                            version: [
                              type: :string,
                              default: "1",
                              doc: "Change it to invalidate every cache."
                            ]
                          ]
                        ]
                      ]
                    ],
                    user: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        change_email: [
                          type: :keyword_list,
                          default: [],
                          keys: [
                            enabled: [type: :boolean, default: false],
                            confirm_current_email: [
                              type: :boolean,
                              default: false,
                              doc: "Confirm from the current address before mailing the new one."
                            ]
                          ]
                        ],
                        delete_user: [
                          type: :keyword_list,
                          default: [],
                          keys: [
                            enabled: [type: :boolean, default: false],
                            verify_with_email: [type: :boolean, default: false],
                            expires_in: [type: :pos_integer, default: @day]
                          ]
                        ]
                      ]
                    ],
                    cookies: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        prefix: [type: :string, default: "authmk"],
                        secure: [type: {:in, [:auto, true, false]}, default: :auto],
                        same_site: [type: {:in, ["Lax", "Strict", "None"]}, default: "Lax"],
                        domain: [type: :string],
                        session_token: [
                          type: :keyword_list,
                          doc: "Overrides for the session_token cookie.",
                          keys: [
                            name: [type: :string],
                            same_site: [type: {:in, ["Lax", "Strict", "None"]}],
                            domain: [type: :string]
                          ]
                        ],
                        session_data: [
                          type: :keyword_list,
                          doc: "Overrides for the session_data cookie.",
                          keys: [
                            name: [type: :string],
                            same_site: [type: {:in, ["Lax", "Strict", "None"]}],
                            domain: [type: :string]
                          ]
                        ],
                        dont_remember: [
                          type: :keyword_list,
                          doc: "Overrides for the dont_remember cookie.",
                          keys: [
                            name: [type: :string],
                            same_site: [type: {:in, ["Lax", "Strict", "None"]}],
                            domain: [type: :string]
                          ]
                        ]
                      ]
                    ],
                    rate_limit: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        enabled: [type: :boolean, default: true],
                        window: [type: :pos_integer, default: 10, doc: "Seconds."],
                        storage: [
                          type: {:in, [:memory, :secondary_storage, :database]},
                          default: :memory,
                          doc: "`:database` needs `Authmk.Plugins.DatabaseRateLimit`."
                        ],
                        max: [type: :pos_integer, default: 100],
                        rules: [
                          type: {:map, :string, {:or, [{:in, [false]}, :keyword_list]}},
                          default: %{},
                          doc:
                            ~s(Per-path rules, like `%{"/sign-in/email" => [window: 60, max: 5]}`, or `false`.)
                        ]
                      ]
                    ],
                    advanced: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        ip_address_headers: [
                          type: {:list, :string},
                          default: [],
                          doc:
                            "Headers holding the client IP, like `x-forwarded-for`. Only set this behind a trusted proxy."
                        ],
                        disable_ip_tracking: [type: :boolean, default: false],
                        disable_origin_check: [type: :boolean, default: false],
                        http_options: [
                          type: :keyword_list,
                          default: [],
                          doc:
                            "Extra `Req` options for outbound requests to OAuth providers, like a test stub."
                        ],
                        validate_schema: [
                          type: :boolean,
                          default: false,
                          doc:
                            "Check at startup that the database has every table and column. See `Authmk.SchemaCheck`."
                        ]
                      ]
                    ]
                  )

  def compile, do: @compile_schema
  def runtime, do: @runtime_schema
end
