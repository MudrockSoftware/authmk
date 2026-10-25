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
                    primary_key: [type: {:in, [:binary_id, :id]}, default: :binary_id]
                  )

  @runtime_schema NimbleOptions.new!(
                    base_url: [
                      type: :string,
                      required: true,
                      doc:
                        "Public URL of your app, like `https://example.com`. Used in links and origin checks."
                    ],
                    base_path: [
                      type: :string,
                      default: "/auth",
                      doc: "Where the auth router is mounted."
                    ],
                    app_name: [type: :string, default: "authmk"],
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
                        disable_refresh: [type: :boolean, default: false]
                      ]
                    ],
                    user: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        change_email: [
                          type: :keyword_list,
                          default: [],
                          keys: [enabled: [type: :boolean, default: false]]
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
                        domain: [type: :string]
                      ]
                    ],
                    rate_limit: [
                      type: :keyword_list,
                      default: [],
                      keys: [
                        enabled: [type: :boolean, default: true],
                        window: [type: :pos_integer, default: 10, doc: "Seconds."],
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
                        disable_origin_check: [type: :boolean, default: false]
                      ]
                    ]
                  )

  def compile, do: @compile_schema
  def runtime, do: @runtime_schema
end
