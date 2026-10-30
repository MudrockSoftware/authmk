defmodule Authmk.Plugins.Autumn do
  @moduledoc """
  Pricing and billing logic with Autumn (useautumn.com): Autumn keeps the
  plans, balances and what each customer may use; authmk connects your
  users and organizations to it.

      use Authmk,
        plugins: [
          {Authmk.Plugins.Autumn,
           api_key: &MyApp.autumn_key/0,
           webhook_secret: &MyApp.autumn_webhook_secret/0,
           on_event: &MyApp.Billing.autumn_event/2}
        ],
        ...

  Autumn's customer id is `user_<id>` (or `org_<id>` for an organization).

  | Method | Path | Session |
  |---|---|---|
  | POST | `/billing/checkout` | required |
  | POST | `/billing/portal` | required |
  | POST | `/billing/cancel` | required |
  | POST | `/billing/webhook` | none (signed by Autumn) |

  `POST /billing/checkout` attaches an Autumn plan (`plan`) and answers with
  the URL to pay at, or `redirect: false` when nothing needs paying.
  `POST /billing/cancel` takes the `plan`, and `immediately`. With
  `organizations: true`, `reference_id` names an organization, as in
  `Authmk.Payments`.

  From your code:

      Authmk.Plugins.Autumn.check(MyApp.Auth, user.id, "messages")       # {:ok, true}
      Authmk.Plugins.Autumn.track(MyApp.Auth, {:organization, org.id}, "messages", 1)

  `check/4` answers `false` when Autumn can't be asked, and when Autumn
  says it's degraded and allowing everything (HTTP 202): no access that
  Autumn didn't grant.

  Webhooks (Autumn's, through Svix) are checked (HMAC-SHA256 over the
  message id, timestamp and body, at most 5 minutes old), then given to
  `on_event`.

  ## Options

    * `:api_key` - Autumn's secret key, or a function returning it (required)
    * `:webhook_secret` - the webhook's `whsec_...` secret, or a function returning it
    * `:api_version` - Autumn's API version (default `"2.6.0"`)
    * `:on_event` - `fn event, ctx -> ... end`, for verified webhooks
    * `:organizations`, `:authorize_reference` - as in `Authmk.Payments`
  """

  use Authmk.Plugin

  require Logger

  alias Authmk.{Context, Endpoint, Error, Origin}
  alias Authmk.OAuth.HTTP
  alias Authmk.Payments.{Client, Options, Reference, Webhook}
  alias Authmk.Plug.RawBody

  @api "https://api.useautumn.com/v1"

  @impl true
  def init(opts) do
    NimbleOptions.validate!(opts,
      api_key: [type: {:or, [:string, {:fun, 0}]}, required: true],
      webhook_secret: [type: {:or, [:string, {:fun, 0}]}],
      api_version: [type: :string, default: "2.6.0"],
      on_event: [type: {:fun, 2}],
      organizations: [type: :boolean, default: false],
      authorize_reference: [type: {:fun, 4}]
    )
  end

  @impl true
  def endpoints(_opts) do
    reference = [reference_id: [type: :string]]

    [
      endpoint(:billing_checkout, "/billing/checkout", :checkout,
        session: :required,
        params: reference ++ [plan: [type: :string, required: true], success_url: [type: :string]]
      ),
      endpoint(:billing_portal, "/billing/portal", :portal,
        session: :required,
        params: reference ++ [return_url: [type: :string]]
      ),
      endpoint(:billing_cancel, "/billing/cancel", :cancel,
        session: :required,
        params:
          reference ++
            [plan: [type: :string, required: true], immediately: [type: :boolean, default: false]]
      ),
      endpoint(:billing_webhook, "/billing/webhook", :webhook, origin_check: false)
    ]
  end

  defp endpoint(name, path, function, opts),
    do:
      Endpoint.new(
        [name: name, method: :post, path: path, handler: {__MODULE__, function}] ++ opts
      )

  @doc false
  def checkout(%Context{params: params} = ctx) do
    opts = opts(ctx)

    with {:ok, reference} <- Reference.resolve(ctx, params.reference_id, :checkout, opts),
         {:ok, success_url} <- absolute(ctx, params.success_url),
         {:ok, _customer} <- customer(ctx, reference, opts),
         {:ok, attached} <-
           request(
             ctx,
             "/billing.attach",
             %{
               customer_id: Reference.external_id(reference),
               plan_id: params.plan,
               success_url: success_url
             },
             opts
           ) do
      case attached do
        %{"payment_url" => url} when is_binary(url) -> {:ok, %{url: url, redirect: true}, ctx}
        _paid_or_free -> {:ok, %{url: nil, redirect: false}, ctx}
      end
    end
  end

  @doc false
  def portal(%Context{params: params} = ctx) do
    opts = opts(ctx)

    with {:ok, reference} <- Reference.resolve(ctx, params.reference_id, :portal, opts),
         {:ok, return_url} <- absolute(ctx, params.return_url),
         {:ok, %{"url" => url}} <-
           request(
             ctx,
             "/billing.open_customer_portal",
             %{customer_id: Reference.external_id(reference), return_url: return_url},
             opts
           ) do
      {:ok, %{url: url, redirect: true}, ctx}
    end
  end

  @doc false
  def cancel(%Context{params: params} = ctx) do
    opts = opts(ctx)
    action = if params.immediately, do: "cancel_immediately", else: "cancel_end_of_cycle"

    with {:ok, reference} <- Reference.resolve(ctx, params.reference_id, :cancel, opts),
         {:ok, _updated} <-
           request(
             ctx,
             "/billing.update",
             %{
               customer_id: Reference.external_id(reference),
               plan_id: params.plan,
               cancel_action: action
             },
             opts
           ) do
      {:ok, %{success: true}, ctx}
    end
  end

  @doc false
  def webhook(%Context{conn: conn} = ctx) do
    opts = opts(ctx)
    headers = Map.new(conn.req_headers)

    signature = %{
      id: headers["svix-id"],
      timestamp: headers["svix-timestamp"],
      signature: headers["svix-signature"]
    }

    with secret when is_binary(secret) <-
           Options.secret(opts[:webhook_secret]) || {:error, :no_secret},
         body when is_binary(body) <- RawBody.get(conn) || {:error, :raw_body_unavailable},
         :ok <- Webhook.standard(signature, body, Webhook.standard_key(secret)),
         {:ok, event} <- JSON.decode(body) do
      if opts[:on_event], do: opts[:on_event].(event, ctx)
      {:json, 200, %{received: true}, ctx}
    else
      {:error, reason} when is_atom(reason) ->
        Logger.warning("authmk Autumn webhook refused (#{reason})")
        {:json, 400, %{error: "invalid_webhook"}, ctx}

      {:error, _decode} ->
        {:json, 400, %{error: "invalid_webhook"}, ctx}
    end
  end

  defp customer(ctx, reference, opts) do
    request(
      ctx,
      "/customers.get_or_create",
      %{
        customer_id: Reference.external_id(reference),
        name: reference.name,
        email: reference.email
      },
      opts
    )
  end

  defp absolute(_ctx, nil), do: {:ok, nil}

  defp absolute(ctx, url) do
    with :ok <- Origin.check_redirect(ctx, url) do
      if String.starts_with?(url, "/"),
        do: {:ok, String.trim_trailing(ctx.base_url, "/") <> url},
        else: {:ok, url}
    end
  end

  @doc """
  Whether a user (by id) or `{:organization, id}` may use `feature`
  (Autumn's feature id), `required` units of it. `false` when Autumn can't
  be asked or answers degraded (202).
  """
  @spec check(module(), Authmk.Payments.billed(), String.t(), number()) :: {:ok, boolean()}
  def check(auth, reference, feature, required \\ 1) do
    {ctx, opts} = server(auth)

    body = %{
      customer_id: external_id(reference),
      feature_id: feature,
      required_balance: required
    }

    # Only a plain 200 counts: 202 means Autumn allowed it without checking.
    case HTTP.post_json(ctx, @api <> "/balances.check", body, headers(opts)) do
      {:ok, 200, %{"allowed" => true}} -> {:ok, true}
      _other -> {:ok, false}
    end
  end

  @doc "Records `value` units of `feature` used by a user (by id) or `{:organization, id}`."
  @spec track(module(), Authmk.Payments.billed(), String.t(), number()) ::
          :ok | {:error, Error.t()}
  def track(auth, reference, feature, value \\ 1) do
    {ctx, opts} = server(auth)
    body = %{customer_id: external_id(reference), feature_id: feature, value: value}
    with {:ok, _tracked} <- request(ctx, "/balances.track", body, opts), do: :ok
  end

  defp external_id(reference), do: reference |> Reference.from_app() |> Reference.external_id()

  defp server(auth) do
    ctx = Context.new(auth.config())
    {ctx, Context.plugin_opts(ctx, __MODULE__)}
  end

  defp request(ctx, path, body, opts),
    do:
      Client.request(
        ctx,
        :post,
        @api <> path,
        Map.reject(body, fn {_k, v} -> is_nil(v) end),
        headers(opts),
        "Autumn"
      )

  defp headers(opts) do
    [
      {"authorization", "Bearer " <> Options.secret(opts[:api_key])},
      {"x-api-version", opts[:api_version]}
    ]
  end

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
