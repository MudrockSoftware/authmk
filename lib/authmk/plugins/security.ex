defmodule Authmk.Plugins.Security do
  @moduledoc """
  Defenses against account attacks and abuse, each turned on by its option:

      use Authmk,
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.Security,
           sign_up_limit: [max: 3, window: 86_400],
           email: [check_mx: true],
           geo_lookup: &MyApp.GeoIP.lookup/1,
           impossible_travel: [action: :block],
           on_event: &MyApp.Alerts.security_event/2}
        ],
        ...

    * **Credential stuffing** (on by default): an IP that fails sign-in for
      too many attempts or accounts is blocked for a while.
    * **Free-trial abuse**: `sign_up_limit` caps sign-ups per IP.
    * **Email checks** on sign-up: disposable providers (on by default),
      domains that can't receive mail (`check_mx`), and with
      `unique_canonical` one mailbox under many spellings
      (`a.b+1@gmail.com`). That last one tells a sign-up that the address
      is taken, so it's off by default: it lets anyone test whether an
      address has an account.
    * **Velocity limits**: `velocity` caps how often one user may call an
      endpoint, like changing their email.
    * **Impossible travel** and **geo-blocking**, with your `geo_lookup`.
    * **Bot blocking** (`block_bots`) and **IP blocking** (`blocked_ips`,
      `ip_reputation`).
    * **Proof-of-work**: endpoints in `proof_of_work` need a solved
      challenge from `GET /security/challenge`, sent as the
      `x-pow-challenge` and `x-pow-nonce` headers.
    * **Inactive accounts**: users get `last_sign_in_at`; list the dormant
      ones with `inactive_users/2` from a scheduled job.

  Compromised passwords are `Authmk.Plugins.HaveIBeenPwned`'s job.

  Every finding is a security event: `[:authmk, :security, :event]`
  telemetry, and your `on_event`.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.Security.Options.schema())}
  """

  use Authmk.Plugin

  import Ecto.Query

  alias Authmk.{Context, Endpoint, Error, Request, Store, Token}
  alias Authmk.Plugins.Security.{Counters, Email, Events, IP, Options, ProofOfWork, Travel}

  @sign_up [:sign_up_email]

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def schema(_opts) do
    %{
      user: [
        fields: [
          canonical_email: [type: :string, index: true, returned: false, input: false],
          last_sign_in_at: [type: :datetime, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    [
      Endpoint.new(
        name: :security_challenge,
        method: :get,
        path: "/security/challenge",
        handler: {__MODULE__, :challenge},
        rate_limit: [window: 60, max: 30]
      )
    ]
  end

  @doc false
  def challenge(ctx), do: {:ok, ProofOfWork.challenge(ctx, difficulty(ctx, opts(ctx))), ctx}

  @impl true
  def before_endpoint(endpoint, ctx) do
    opts = opts(ctx)

    checks = [
      &check_ip/3,
      &check_region/3,
      &check_bot/3,
      &check_stuffing/3,
      &check_sign_up_limit/3,
      &check_email/3,
      &check_velocity/3,
      &check_proof_of_work/3
    ]

    Enum.reduce_while(checks, {:cont, ctx}, fn check, {:cont, ctx} ->
      case check.(endpoint, ctx, opts) do
        :ok -> {:cont, {:cont, ctx}}
        {:error, %Error{} = error} -> {:halt, {:halt, error}}
      end
    end)
  end

  defp check_ip(_endpoint, ctx, opts) do
    address = Request.client_address(ctx)

    cond do
      IP.member?(address, opts[:blocked_ips]) ->
        refuse(ctx, opts, :blocked_ip, :ip_blocked, 403)

      opts[:ip_reputation] && address && opts[:ip_reputation].(Request.client_ip(ctx)) == :block ->
        refuse(ctx, opts, :suspicious_ip, :ip_blocked, 403)

      true ->
        :ok
    end
  end

  defp check_region(_endpoint, ctx, opts) do
    allowed = opts[:geo_blocking][:allowed_countries]
    blocked = opts[:geo_blocking][:blocked_countries]

    case (allowed || blocked) && location(ctx, opts) do
      %{country: country} when is_binary(country) ->
        if (allowed && country not in allowed) || (blocked && country in blocked),
          do: refuse(ctx, opts, :region_blocked, :region_blocked, 403, %{country: country}),
          else: :ok

      _unknown ->
        :ok
    end
  end

  @bots ~r/curl|wget|python-requests|python-urllib|aiohttp|go-http-client|okhttp|java\/|libwww|httpclient|scrapy|headlesschrome|phantomjs|selenium|puppeteer|playwright/i

  defp check_bot(endpoint, ctx, opts) do
    agent = Request.user_agent(ctx)

    if opts[:block_bots] and endpoint in (@sign_up ++ Options.sign_in_endpoints()) and
         (agent in [nil, ""] or Regex.match?(@bots, agent)),
       do: refuse(ctx, opts, :bot, :bot_blocked, 403, %{user_agent: agent}),
       else: :ok
  end

  defp check_stuffing(endpoint, ctx, opts) do
    if opts[:credential_stuffing] != false and endpoint in Options.sign_in_endpoints() and
         Counters.get(ctx, "cs-block:" <> ip(ctx)),
       do:
         {:error,
          Error.custom(:too_many_attempts, 429, "Too many failed sign-ins from here. Try later")},
       else: :ok
  end

  defp check_sign_up_limit(endpoint, ctx, opts) do
    limit = opts[:sign_up_limit]

    with true <- limit != false and endpoint in @sign_up,
         count when is_binary(count) <- Counters.get(ctx, sign_up_key(ctx, limit)),
         true <- String.to_integer(count) >= limit[:max] do
      refuse(ctx, opts, :sign_up_limit, :too_many_sign_ups, 429)
    else
      _under_limit -> :ok
    end
  end

  defp check_email(endpoint, %Context{raw_params: %{"email" => email}} = ctx, opts)
       when endpoint in @sign_up and is_binary(email) do
    rules =
      Keyword.merge(
        [block_disposable: true, check_mx: false, unique_canonical: false],
        opts[:email]
      )

    case String.contains?(email, "@") && email_problem(ctx, email, rules) do
      {type, code, status} -> refuse(ctx, opts, type, code, status)
      _fine -> :ok
    end
  end

  defp check_email(_endpoint, _ctx, _opts), do: :ok

  defp email_problem(ctx, email, rules) do
    cond do
      rules[:block_disposable] and Email.disposable?(email) ->
        {:disposable_email, :disposable_email, 400}

      rules[:check_mx] and not Email.receives_mail?(email, rules[:resolve_mx]) ->
        {:undeliverable_email, :email_cannot_receive_mail, 400}

      rules[:unique_canonical] and canonical_taken?(ctx, email) ->
        {:duplicate_mailbox, :email_already_used, 422}

      true ->
        nil
    end
  end

  defp canonical_taken?(ctx, email) do
    case Store.get_by(ctx, :user, canonical_email: Email.canonical(email)) do
      nil -> false
      user -> user.email != String.downcase(email)
    end
  end

  defp check_velocity(endpoint, %Context{user: user} = ctx, opts) do
    case {opts[:velocity][endpoint], user} do
      {limit, %{id: id}} when is_list(limit) ->
        count = Counters.increment(ctx, "velocity:#{endpoint}:#{id}", limit[:window])

        if count > limit[:max],
          do: refuse(ctx, opts, :velocity, :velocity_limited, 429, %{endpoint: endpoint}),
          else: :ok

      _no_limit ->
        :ok
    end
  end

  defp check_proof_of_work(endpoint, ctx, opts) do
    if endpoint in (opts[:proof_of_work][:endpoints] || []) and ProofOfWork.verify(ctx) != :ok,
      do:
        {:error,
         Error.custom(
           :proof_of_work_required,
           400,
           "Solve a challenge from /security/challenge first"
         )},
      else: :ok
  end

  defp difficulty(ctx, opts) do
    case opts[:proof_of_work][:difficulty] do
      nil -> 18
      bits when is_integer(bits) -> bits
      fun -> fun.(ctx)
    end
  end

  # Failed sign-ins count against the IP; successful sign-ups too.
  @impl true
  def after_endpoint(endpoint, ctx, {:error, %Error{code: :invalid_credentials}} = result) do
    _counted = if endpoint in Options.sign_in_endpoints(), do: count_failure(ctx, opts(ctx))
    result
  end

  def after_endpoint(endpoint, ctx, {:ok, _body, _result_ctx} = result)
      when endpoint in @sign_up do
    limit = opts(ctx)[:sign_up_limit]

    _count =
      if limit != false, do: Counters.increment(ctx, sign_up_key(ctx, limit), limit[:window])

    result
  end

  def after_endpoint(_endpoint, _ctx, result), do: result

  defp count_failure(%Context{raw_params: params} = ctx, opts) do
    rules =
      Keyword.merge(
        [max_failures: 20, max_accounts: 5, window: 600, block_for: 900],
        opts[:credential_stuffing] || []
      )

    if opts[:credential_stuffing] != false do
      ip = ip(ctx)
      account = params["email"] || params["username"] || params["phone_number"] || ""
      failures = Counters.increment(ctx, "cs-fail:" <> ip, rules[:window])

      first_for_account =
        Counters.increment(ctx, "cs-acct:#{ip}:#{Token.hash(account)}", rules[:window]) == 1

      accounts =
        if first_for_account,
          do: Counters.increment(ctx, "cs-accts:" <> ip, rules[:window]),
          else: 0

      if failures >= rules[:max_failures] or accounts >= rules[:max_accounts] do
        :ok = Counters.put(ctx, "cs-block:" <> ip, "1", rules[:block_for])
        Events.emit(ctx, opts, :credential_stuffing, %{failures: failures, accounts: accounts})
      end
    end
  end

  @impl true
  def database_hook(:before_create, :session, attrs, ctx), do: check_travel(ctx, attrs)

  # Sign-ins are dated, without user hooks (it isn't a profile change).
  def database_hook(:after_create, :session, session, ctx) do
    now = DateTime.utc_now()
    query = from(u in Store.module(ctx, :user), where: u.id == ^session.user_id)
    _count = Store.update_all(ctx, :user, query, set: [last_sign_in_at: now])
    {:ok, session}
  end

  def database_hook(event, :user, attrs, _ctx)
      when event in [:before_create, :before_update] and is_map(attrs) do
    # Same key type as the email: request input has string keys, authmk's own
    # writes atom keys, and changesets refuse a mix.
    cond do
      is_binary(attrs[:email]) ->
        {:ok, Map.put(attrs, :canonical_email, Email.canonical(attrs[:email]))}

      is_binary(attrs["email"]) ->
        {:ok, Map.put(attrs, "canonical_email", Email.canonical(attrs["email"]))}

      true ->
        {:ok, attrs}
    end
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  defp check_travel(ctx, attrs) do
    opts = opts(ctx)
    rules = opts[:impossible_travel]

    with true <- rules != false and ctx.conn != nil,
         %{latitude: lat, longitude: lon} <- location(ctx, opts) do
      key = "travel:#{attrs.user_id}"
      now = System.system_time(:second)
      flagged = too_fast?(Counters.get(ctx, key), {lat, lon}, now, rules[:max_speed_kmh] || 1000)
      block = flagged and rules[:action] == :block

      if flagged,
        do:
          :ok =
            Events.emit(ctx, opts, :impossible_travel, %{user_id: attrs.user_id, blocked: block})

      if block do
        {:error,
         Error.custom(:sign_in_blocked, 403, "This sign-in looks unusual and was blocked")}
      else
        :ok = Counters.put(ctx, key, JSON.encode!([lat, lon, now]), 90 * 86_400)
        {:ok, attrs}
      end
    else
      _unknown -> {:ok, attrs}
    end
  end

  defp too_fast?(nil, _here, _now, _max), do: false

  defp too_fast?(last, here, now, max) do
    case JSON.decode(last) do
      {:ok, [lat, lon, at]} -> Travel.speed_kmh({lat, lon}, here, now - at) > max
      _invalid -> false
    end
  end

  # Looked up once an hour per IP.
  defp location(ctx, opts) do
    ip = Request.client_ip(ctx)

    if is_function(opts[:geo_lookup], 1) and is_binary(ip),
      do: cached_location(ctx, opts[:geo_lookup], ip),
      else: nil
  end

  defp cached_location(ctx, fun, ip) do
    case Counters.get(ctx, "geo:" <> ip) do
      nil ->
        location = lookup(fun, ip)
        :ok = Counters.put(ctx, "geo:" <> ip, JSON.encode!(location || %{}), 3600)
        location

      "{}" ->
        nil

      cached ->
        cached |> JSON.decode!() |> atomize()
    end
  end

  defp lookup(fun, ip) do
    case fun.(ip) do
      {:ok, %{} = location} -> Map.take(location, [:country, :latitude, :longitude])
      _unknown -> nil
    end
  end

  defp atomize(map),
    do: %{country: map["country"], latitude: map["latitude"], longitude: map["longitude"]}

  @doc """
  Users who haven't signed in for `days` (or ever, and joined before then),
  oldest first, for a scheduled job to warn or disable them. `limit:`
  (default 100).
  """
  @spec inactive_users(module(), pos_integer(), keyword()) :: [struct()]
  def inactive_users(auth, days, opts \\ []) do
    ctx = Context.new(auth.config())
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400)

    query =
      from(u in Store.module(ctx, :user),
        where:
          u.last_sign_in_at < ^cutoff or (is_nil(u.last_sign_in_at) and u.inserted_at < ^cutoff),
        order_by: [asc: coalesce(u.last_sign_in_at, u.inserted_at)],
        limit: ^Keyword.get(opts, :limit, 100)
      )

    Store.list(ctx, :user, query)
  end

  defp refuse(ctx, opts, type, code, status, details \\ %{}) do
    :ok = Events.emit(ctx, opts, type, details)
    {:error, Error.custom(code, status, message(code))}
  end

  defp message(:ip_blocked), do: "Requests from this address aren't accepted"
  defp message(:region_blocked), do: "This service isn't available in your region"
  defp message(:bot_blocked), do: "Automated requests aren't accepted"
  defp message(:too_many_sign_ups), do: "Too many sign-ups from here. Try later"
  defp message(:disposable_email), do: "Use a permanent email address"
  defp message(:email_cannot_receive_mail), do: "This email domain can't receive mail"
  defp message(:email_already_used), do: "This mailbox already has an account"
  defp message(:velocity_limited), do: "You've done this too often. Try later"

  defp sign_up_key(ctx, limit),
    do: "sign-ups:#{ip(ctx)}:#{div(System.system_time(:second), limit[:window])}"

  defp ip(ctx), do: Request.client_ip(ctx) || "unknown"

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
