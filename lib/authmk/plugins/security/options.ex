defmodule Authmk.Plugins.Security.Options do
  @moduledoc false

  @sign_in [:sign_in_email, :sign_in_username, :sign_in_phone_number, :sign_in_email_otp]

  def sign_in_endpoints, do: @sign_in

  def schema do
    NimbleOptions.new!(
      credential_stuffing: [
        type: {:or, [:keyword_list, {:in, [false]}]},
        default: [],
        doc:
          "Blocks an IP that fails sign-in for many accounts: `max_failures` (default 20) or `max_accounts` (default 5) within `window` seconds (600) blocks it for `block_for` seconds (900). `false` turns it off."
      ],
      sign_up_limit: [
        type: {:or, [:keyword_list, {:in, [false]}]},
        default: false,
        doc:
          "Free-trial abuse: at most `max` sign-ups per IP within `window` seconds, like `[max: 3, window: 86_400]`."
      ],
      velocity: [
        type: :keyword_list,
        default: [],
        doc:
          "Per-user limits on endpoints, `endpoint_name: [max: 5, window: 3600]`, like `change_email: [max: 3, window: 86_400]`."
      ],
      email: [
        type: :keyword_list,
        default: [],
        doc:
          "Sign-up email checks: `block_disposable` (default true), `check_mx` (default false), `unique_canonical` (default true: `a.b+tag@gmail.com` counts as `ab@gmail.com` for uniqueness), `resolve_mx` (`fn domain -> {:ok, [host]} | :error end`)."
      ],
      geo_lookup: [
        type: {:fun, 1},
        doc:
          "`fn ip -> {:ok, %{country: \"DE\", latitude: 52.5, longitude: 13.4}} | :error end`, from your GeoIP database. Needed for `geo_blocking` and `impossible_travel`."
      ],
      geo_blocking: [
        type: :keyword_list,
        default: [],
        doc: "`allowed_countries:` or `blocked_countries:` (ISO codes). Unknown locations pass."
      ],
      impossible_travel: [
        type: {:or, [:keyword_list, {:in, [false]}]},
        default: false,
        doc:
          "Flags sign-ins farther from the last one than `max_speed_kmh` (default 1000) allows; `action: :block` refuses them, `:report` (default) only reports."
      ],
      blocked_ips: [
        type: {:list, :string},
        default: [],
        doc: "IPs and CIDR ranges (`\"203.0.113.0/24\"`) that get nowhere."
      ],
      ip_reputation: [
        type: {:fun, 1},
        doc:
          "`fn ip -> :ok | :block end`: your IP intelligence. Blocks are reported as `:suspicious_ip`."
      ],
      block_bots: [
        type: :boolean,
        default: false,
        doc:
          "Refuses requests without a user agent, or with one of a known automation tool (curl, python-requests, headless browsers), on the sign-in and sign-up endpoints."
      ],
      proof_of_work: [
        type: :keyword_list,
        default: [],
        doc:
          "`endpoints:` that need a solved challenge (from `GET /security/challenge`), and `difficulty:` in leading zero bits (default 18), or a `fn ctx -> bits end`."
      ],
      on_event: [
        type: {:fun, 2},
        doc:
          "`fn event, ctx -> any end` for every security event (`%{type:, ip:, user_id:, details:}`). They're also `[:authmk, :security, :event]` telemetry."
      ]
    )
  end
end
