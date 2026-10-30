# Payments

authmk connects your users and organizations to a payment provider:
Stripe, Polar, Chargebee, Creem, Dodo Payments or Commet through
`Authmk.Payments`, or Autumn through its own plugin. Use one provider per
app. Your provider keeps the cards, invoices and prices. authmk keeps a copy
of each subscription so your code can check it without calling the
provider.

## Setup

Add the plugin with your plans. Read keys from functions, so they stay out
of compiled config:

```elixir
use Authmk,
  plugins: [
    {Authmk.Plugins.Stripe,
     api_key: &MyApp.Billing.stripe_key/0,
     webhook_secret: &MyApp.Billing.stripe_webhook_secret/0,
     organizations: true,
     plans: [
       [name: "pro", id: "price_pro_monthly", annual_id: "price_pro_yearly",
        trial_days: 14, limits: %{projects: 50}]
     ]}
  ]
```

Then run `mix authmk.gen.migration` and `mix ecto.migrate`.

Webhook signatures are computed over the exact bytes the provider sent, so
`Plug.Parsers` has to keep them. In a Phoenix endpoint, or a Plug router:

```elixir
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  json_decoder: JSON,
  body_reader: {Authmk.Plug.RawBody, :read_body, []}
```

Without it, webhooks are answered with a 500 and a log line saying what's
missing.

Finally, point the provider's webhook at `<base URL>/billing/webhook` and
send it the subscription events. Each plugin's documentation lists them.

## Checking out

```
POST /auth/billing/checkout  {"plan": "pro", "annual": true, "success_url": "/welcome"}
→ {"url": "https://checkout.stripe.com/...", "redirect": true}
```

Send the browser to `url`. `success_url` and `cancel_url` must be relative
paths or trusted origins. When the user has paid, the provider's webhook
creates the subscription in your database.

For an organization, add `reference_id` with the organization's id. Only
its owners and admins may manage its billing, unless you pass
`authorize_reference`.

`POST /auth/billing/portal` opens the provider's customer portal, where
users change plans, update cards and see invoices. `POST /auth/billing/cancel`
cancels at the end of the period, or now with `immediately: true`.
`GET /auth/billing/subscriptions` lists them.

## Checking access

```elixir
Authmk.Payments.allowed?(MyApp.Auth, user.id, :projects, 3)
Authmk.Payments.plan(MyApp.Auth, {:organization, org.id})
Authmk.Payments.active_subscription(MyApp.Auth, user.id)
```

A user is named by their id and an organization by `{:organization, id}`.
The two are never mixed up, even with integer ids. Only `active` and
`trialing` subscriptions within their period grant access. A subscription
that is `past_due`, `unpaid`, `paused`, `incomplete` or `canceled` grants
nothing.

Commet and Autumn decide access themselves: `Authmk.Plugins.Commet.check/3`
and `Authmk.Plugins.Autumn.check/4` ask them, and answer `false` when they
can't be reached.

## What authmk guarantees

These hold for the plugins built on `Authmk.Payments`. Autumn keeps plans
and balances itself: its webhooks are verified and handed to your
`on_event`, and Autumn decides the rest.

- **Webhooks are verified, then re-read.** A webhook must carry a valid
  signature, and it is refused when it's more than 5 minutes old (for
  providers that sign a timestamp). Even then authmk only takes the
  subscription's id from it, and reads the subscription from the
  provider's API. A replayed, reordered or tampered payload can't change
  what's stored.
- **Webhooks that can't be saved fail.** authmk answers 500, so the
  provider sends the webhook again. Syncing the same subscription twice
  changes nothing.
- **One subscription at a time.** A user or organization with a
  subscription that is active, trialing or waiting for payment can't check
  out again. Plans change in the provider's portal, so nobody pays twice.
- **One trial each.** Whatever the plan or provider, a user or
  organization that had a trial checks out without one. With providers that
  set trials on the product, give the plan a `no_trial_id`.
- **Provider errors stay generic.** Users see `payment_provider_error` or
  `payment_provider_unavailable`. The provider's own message isn't passed
  on.

## Lifecycle hooks

The plugin's options take `on_subscription_created`, `on_subscription_updated`,
`on_subscription_canceled`, `on_trial_started` and `on_trial_ended`. Each
is a `fn subscription, ctx -> ... end`, and it runs once per change, as
the change is saved.
