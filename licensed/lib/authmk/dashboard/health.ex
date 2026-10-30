defmodule Authmk.Dashboard.Health do
  @moduledoc false
  # Health checks for what the app's auth depends on. Each check is
  # `%{area:, name:, status:, message:, expires_at:}`, with status "ok",
  # "warning", "failing" or "unknown".
  #
  # `checks(ctx, network: false)` stays on this node (fast enough for the
  # home page's warnings): the audit log, email and SMS deliveries,
  # certificates and secrets that expire, SCIM, payments, secondary
  # storage and background jobs. `network: true` also asks each social and
  # SSO provider: its discovery document, and whether it accepts our client
  # credentials (a token request with a code that can't work: a provider
  # that knows the client answers `invalid_grant`).

  import Ecto.Query

  alias Authmk.{Background, Deliveries, Storage, Store}
  alias Authmk.Dashboard.Data
  alias Authmk.OAuth.Discovery
  alias Authmk.Plugins.{AuditLog, SSO}
  alias Authmk.Plugins.SSO.Providers, as: SSOProviders
  alias Authmk.Plugins.SSO.SAML.Certificates

  @soon 30 * 86_400
  @network_timeout 15_000
  @rejected_client ~w(invalid_client unauthorized_client incorrect_client_credentials)

  def checks(ctx, opts) do
    local =
      [audit_log(ctx)] ++
        deliveries(ctx) ++
        certificates(ctx) ++
        secrets(ctx) ++
        scim(ctx) ++
        payments(ctx) ++
        [storage(ctx), background(ctx)]

    local = Enum.reject(local, &is_nil/1)
    if opts[:network], do: local ++ providers(ctx), else: local
  end

  defp check(area, name, status, message, expires_at \\ nil),
    do: %{area: area, name: name, status: status, message: message, expires_at: expires_at}

  ## On this node

  defp audit_log(ctx) do
    if Data.enabled?(ctx, AuditLog),
      do: check("Audit log", "Audit log", "ok", "Changes made here are recorded."),
      else:
        check(
          "Audit log",
          "Audit log",
          "warning",
          "Changes made here aren't recorded: add Authmk.Plugins.AuditLog."
        )
  end

  # Known once something was handed to a sender on this node.
  defp deliveries(ctx) do
    case Deliveries.list(ctx.config.auth) do
      [] ->
        message = "Nothing has been sent since this node started."
        [check("Email", "Email and SMS", "unknown", message)]

      deliveries ->
        Enum.map(deliveries, &delivery/1)
    end
  end

  defp delivery(delivery) do
    area = if delivery.channel == :sms, do: "SMS", else: "Email"
    check(area, delivery.name, delivery_status(delivery), delivery_message(delivery))
  end

  defp delivery_status(%{not_implemented: true}), do: "failing"
  defp delivery_status(%{last_failed_at: nil}), do: "ok"
  defp delivery_status(%{last_sent_at: nil}), do: "failing"

  defp delivery_status(delivery),
    do:
      if(DateTime.after?(delivery.last_failed_at, delivery.last_sent_at),
        do: "failing",
        else: "ok"
      )

  defp delivery_message(%{not_implemented: true}),
    do: "Not implemented by the auth module: nothing is sent."

  defp delivery_message(%{last_failed_at: nil} = delivery),
    do: "Last handed to the sender #{ago(delivery.last_sent_at)}."

  defp delivery_message(delivery),
    do: "Last failed #{ago(delivery.last_failed_at)} (#{delivery.failure})."

  # SAML certificates: the identity providers', and ours.
  defp certificates(ctx) do
    if Data.enabled?(ctx, SSO) do
      providers =
        for provider <- sso_providers(ctx),
            %{certificates: certificates} <- [provider.saml],
            certificate <- certificates,
            do:
              expiry(
                "SSO",
                "#{provider.provider_id} certificate",
                Certificates.expires_at(certificate)
              )

      ours =
        for key <- signing_keys(ctx),
            {:ok, certificate} <- [Certificates.parse(key[:certificate] || "")],
            do:
              expiry("SSO", "Our SAML signing certificate", Certificates.expires_at(certificate))

      providers ++ ours
    else
      []
    end
  end

  defp signing_keys(ctx) do
    case Authmk.Context.plugin_opts(ctx, SSO)[:saml][:signing_keys] do
      keys when is_function(keys, 0) -> keys.()
      keys when is_list(keys) -> keys
      _none -> []
    end
  end

  # Client secrets that are JWTs (Apple's) carry their expiry.
  defp secrets(ctx) do
    for {id, provider} <- ctx.config.social_providers,
        expires_at = jwt_expiry(provider.client_secret),
        do: expiry("Social sign-in", "#{id} client secret", expires_at)
  end

  defp jwt_expiry(secret) when is_binary(secret) do
    with [_header, payload, _signature] <- String.split(secret, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- JSON.decode(json) do
      DateTime.from_unix!(exp)
    else
      _not_a_jwt -> nil
    end
  end

  defp jwt_expiry(_secret), do: nil

  defp expiry(area, name, nil), do: check(area, name, "unknown", "Its expiry can't be read.")

  defp expiry(area, name, expires_at) do
    seconds = DateTime.diff(expires_at, DateTime.utc_now())

    cond do
      seconds <= 0 -> check(area, name, "failing", "Expired #{ago(expires_at)}.", expires_at)
      seconds <= @soon -> check(area, name, "warning", "Expires in #{days(seconds)}.", expires_at)
      true -> check(area, name, "ok", "Valid for #{days(seconds)}.", expires_at)
    end
  end

  defp scim(ctx) do
    for connection <- Data.all(ctx, :scim_connection, 50) do
      name = "SCIM: " <> (connection.name || connection.provider_id || to_string(connection.id))

      cond do
        connection.status != "active" ->
          check("SCIM", name, "ok", "Turned off (#{connection.status}).")

        is_nil(connection.last_used_at) ->
          check("SCIM", name, "warning", "The directory hasn't connected yet.")

        true ->
          check("SCIM", name, "ok", "Last synced #{ago(connection.last_used_at)}.")
      end
    end
  end

  # The provider's keys are there, plans have prices for earnings, and
  # webhooks arrive (subscriptions are only ever changed by them and by
  # admins).
  defp payments(ctx) do
    case Authmk.Payments.provider(ctx.config.auth) do
      nil ->
        []

      {plugin, opts} ->
        name = plugin.provider()
        priced = Enum.all?(opts[:plans], &(&1[:amount] || &1[:annual_amount]))

        [
          check(
            "Payments",
            "#{name} plans",
            if(priced, do: "ok", else: "warning"),
            if(priced,
              do: "Every plan has a price.",
              else: "Some plans have no amount: earnings leave them out."
            )
          ),
          webhooks(ctx, name)
        ]
    end
  end

  defp webhooks(ctx, name) do
    latest =
      Store.one(
        ctx,
        :subscription,
        from(s in Store.module(ctx, :subscription),
          order_by: [desc: s.updated_at],
          limit: 1,
          select: s.updated_at
        )
      )

    if latest,
      do: check("Payments", "#{name} webhooks", "ok", "Last subscription change #{ago(latest)}."),
      else: check("Payments", "#{name} webhooks", "unknown", "No subscription has arrived yet.")
  end

  # Writes, reads and deletes a key it made up.
  defp storage(%{config: config}) do
    if Storage.configured?(config) do
      key = "authmk-health:" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
      started = System.monotonic_time(:millisecond)

      try do
        :ok = Storage.put(config, key, "ok", 60)
        value = Storage.get(config, key)
        :ok = Storage.delete(config, key)
        took = System.monotonic_time(:millisecond) - started

        if value == "ok",
          do: check("Secondary storage", "Secondary storage", "ok", "Answered in #{took} ms."),
          else:
            check(
              "Secondary storage",
              "Secondary storage",
              "failing",
              "It lost what it was given."
            )
      rescue
        exception ->
          message = "It can't be reached (#{inspect(exception.__struct__)})."
          check("Secondary storage", "Secondary storage", "failing", message)
      end
    end
  end

  defp background(%{config: config} = ctx) do
    case config.background do
      :inline ->
        check("Background jobs", "Background jobs", "ok", "Run during each request.")

      :task ->
        if Process.whereis(Background.task_supervisor(config.auth)),
          do: check("Background jobs", "Background jobs", "ok", "Run in supervised tasks."),
          else:
            check(
              "Background jobs",
              "Background jobs",
              "failing",
              "The task supervisor isn't running."
            )

      {:oban, opts} ->
        oban(ctx, opts)
    end
  end

  # Oban is optional: called by name.
  # credo:disable-for-lines:20 Credo.Check.Refactor.Apply
  defp oban(ctx, opts) do
    name = Keyword.get(opts, :name, Oban)
    running = Code.ensure_loaded?(Oban) and apply(Oban, :whereis, [name]) != nil

    cond do
      not running ->
        check(
          "Background jobs",
          "Oban",
          "failing",
          "Oban isn't running: emails wait in the queue."
        )

      (discarded = discarded_jobs(ctx)) > 0 ->
        check("Background jobs", "Oban", "warning", "#{discarded} jobs gave up in the last week.")

      true ->
        check("Background jobs", "Oban", "ok", "Running.")
    end
  end

  defp discarded_jobs(%{config: config}) do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86_400)

    config.repo.aggregate(
      from(j in "oban_jobs",
        where:
          j.worker == "Authmk.Background.ObanWorker" and j.state == "discarded" and
            j.discarded_at > ^week_ago
      ),
      :count
    )
  rescue
    _unavailable -> 0
  end

  ## Asking the providers

  defp providers(ctx) do
    social =
      for {id, provider} <- ctx.config.social_providers,
          do: {"Social sign-in", to_string(id), provider, ctx}

    sso =
      for provider <- sso_providers(ctx), provider.saml == nil do
        sso_ctx = sso_context(ctx)

        {"SSO", provider.provider_id, SSOProviders.oauth_provider(sso_ctx, provider),
         SSOProviders.http_context(sso_ctx, provider)}
      end

    (social ++ sso)
    |> Task.async_stream(
      fn {area, name, provider, http_ctx} -> ask(http_ctx, area, name, provider) end,
      timeout: @network_timeout,
      on_timeout: :kill_task,
      max_concurrency: 8
    )
    |> Enum.zip(social ++ sso)
    |> Enum.map(fn
      {{:ok, result}, _provider} ->
        result

      {{:exit, _timeout}, {area, name, _, _}} ->
        check(area, name, "failing", "It didn't answer in time.")
    end)
  end

  defp sso_providers(ctx) do
    if Data.enabled?(ctx, SSO), do: SSOProviders.all(sso_context(ctx), 200), else: []
  end

  defp sso_context(ctx), do: Authmk.Context.put_private(ctx, :sso_plugin, SSO)

  defp ask(ctx, area, name, provider) do
    case discover(ctx, provider) do
      {:ok, provider} -> credentials(ctx, area, name, provider)
      {:error, message} -> check(area, name, "failing", message)
    end
  end

  defp discover(ctx, provider) do
    case Discovery.resolve(ctx, provider) do
      {:ok, provider} -> {:ok, provider}
      {:error, _reason} -> {:error, "Its discovery document can't be read."}
    end
  end

  defp credentials(_ctx, area, name, %{token_url: nil}),
    do: check(area, name, "unknown", "It has no token endpoint to ask.")

  defp credentials(ctx, area, name, provider) do
    form = [
      grant_type: "authorization_code",
      code: "authmk-health-check",
      redirect_uri: provider.options[:redirect_uri] || "https://invalid.example/callback"
    ]

    case provider.module.token_request(ctx, provider, form) do
      {:ok, status, body} ->
        if status == 401 or error_code(body) in @rejected_client,
          do: check(area, name, "failing", "It refused our client credentials."),
          else: check(area, name, "ok", "Reachable, and it knows our client.")

      {:error, _reason} ->
        check(area, name, "failing", "It can't be reached.")
    end
  end

  defp error_code(%{"error" => code}) when is_binary(code), do: code
  defp error_code(_body), do: nil

  defp ago(%DateTime{} = time) do
    seconds = DateTime.diff(DateTime.utc_now(), time)

    cond do
      seconds < 120 -> "just now"
      seconds < 7200 -> "#{div(seconds, 60)} minutes ago"
      seconds < 172_800 -> "#{div(seconds, 3600)} hours ago"
      true -> "#{div(seconds, 86_400)} days ago"
    end
  end

  defp days(seconds) when seconds < 172_800, do: "#{max(div(seconds, 3600), 1)} hours"
  defp days(seconds), do: "#{div(seconds, 86_400)} days"
end
