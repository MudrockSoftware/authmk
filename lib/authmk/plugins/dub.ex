defmodule Authmk.Plugins.Dub do
  @moduledoc """
  Dub (dub.co) conversion tracking: sign-ups from Dub links become leads,
  and your code reports sales.

      use Authmk,
        plugins: [{Authmk.Plugins.Dub, api_key: &MyApp.dub_key/0}],
        ...

  Dub's analytics script, on your landing pages, keeps the click in a
  `dub_id` cookie. When someone signs up with it, authmk tracks a lead
  (`POST https://api.dub.co/track/lead`, in the background): the click,
  `lead_event_name`, and the user, as Dub's customer, by their id (with
  their name, email and avatar). Sign-ups without the cookie aren't sent.
  Lead tracking needs Dub's Business plan.

  Sales, from your code (in cents):

      Authmk.Plugins.Dub.track_sale(MyApp.Auth, user.id, 4900, currency: "usd", invoice_id: "in_1")

  To link users' Dub accounts (for integrations), add `dub` to
  `social_providers` (see `Authmk.OAuth.Providers.Dub`).

  ## Options

    * `:api_key` - Dub's API key, or a function returning it (required)
    * `:lead_event_name` - default `"Sign Up"`
  """

  use Authmk.Plugin

  require Logger

  alias Authmk.{Background, Context, Error}
  alias Authmk.Payments.{Client, Options}

  @api "https://api.dub.co"
  @cookie "dub_id"

  @impl true
  def init(opts) do
    NimbleOptions.validate!(opts,
      api_key: [type: {:or, [:string, {:fun, 0}]}, required: true],
      lead_event_name: [type: :string, default: "Sign Up"]
    )
  end

  # A sign-up from a Dub link: the click is in the browser's cookie.
  @impl true
  def database_hook(:after_create, :user, user, %Context{conn: %Plug.Conn{} = conn} = ctx) do
    case Plug.Conn.fetch_cookies(conn).req_cookies[@cookie] do
      click_id when is_binary(click_id) and click_id != "" ->
        Background.call(ctx, __MODULE__, :track_lead, [click_id, lead(user)])

      _no_click ->
        :ok
    end

    :ok
  end

  def database_hook(_event, _model, data, _ctx), do: {:ok, data}

  defp lead(user) do
    %{
      id: to_string(user.id),
      name: user.name,
      email: user.email,
      image: Map.get(user, :image)
    }
  end

  @doc false
  # Background work: see Authmk.Background.
  def track_lead(ctx, click_id, user) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    body =
      %{
        clickId: click_id,
        eventName: opts[:lead_event_name],
        customerExternalId: user.id,
        customerName: user.name,
        customerEmail: user.email,
        customerAvatar: user.image
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    case request(ctx, "/track/lead", body, opts) do
      {:ok, _lead} -> :ok
      {:error, error} -> Logger.warning("authmk Dub: lead not tracked (#{error.code})")
    end
  end

  @doc """
  Reports a sale by a user (Dub's customer, by the user's id): `amount` in
  cents. Options: `:currency` (default `"usd"`), `:event_name`,
  `:invoice_id` (Dub won't count the same invoice twice), `:payment_processor`,
  `:metadata`.
  """
  @spec track_sale(module(), term(), pos_integer(), keyword()) :: :ok | {:error, Error.t()}
  def track_sale(auth, user_id, amount, opts \\ []) when is_integer(amount) do
    ctx = Context.new(auth.config())

    body =
      %{
        customerExternalId: to_string(user_id),
        amount: amount,
        currency: opts[:currency] || "usd",
        eventName: opts[:event_name],
        invoiceId: opts[:invoice_id],
        paymentProcessor: opts[:payment_processor],
        metadata: opts[:metadata]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, _sale} <- request(ctx, "/track/sale", body, Context.plugin_opts(ctx, __MODULE__)),
         do: :ok
  end

  defp request(ctx, path, body, opts) do
    headers = [{"authorization", "Bearer " <> Options.secret(opts[:api_key])}]
    Client.request(ctx, :post, @api <> path, body, headers, "Dub")
  end
end
