defmodule Authmk.Payments.Provider do
  @moduledoc """
  What a payment plugin implements for `Authmk.Payments`' shared endpoints.
  Every call gets the context and the plugin's options. Subscriptions come
  back normalized: `%{provider_subscription_id:, customer_id:, status:,
  price_id:, period_start:, period_end:, cancel_at_period_end:,
  canceled_at:, trial_start:, trial_end:, seats:, reference_id:}`, with
  statuses `active`, `trialing`, `past_due`, `unpaid`, `paused`,
  `incomplete` and `canceled`.

  `change_plan/4` and `resume/3` are optional: a plugin implements them
  when its provider's API can do it, and `Authmk.Payments.supports?/2`
  tells which.
  """

  alias Authmk.{Context, Error}

  @type opts :: keyword()
  @type billed :: %{
          id: String.t(),
          type: String.t(),
          email: String.t() | nil,
          name: String.t() | nil
        }

  @doc "The provider's name, as stored (`\"stripe\"`)."
  @callback provider() :: String.t()

  @doc "Creates the provider's customer for a reference; returns its id."
  @callback create_customer(Context.t(), billed(), opts()) ::
              {:ok, String.t()} | {:error, Error.t()}

  @doc """
  A hosted checkout for `checkout.price_id`: `%{customer_id:, price_id:,
  success_url:, cancel_url:, seats:, trial_days:, reference:}`. Returns the
  URL to send the user to.
  """
  @callback checkout(Context.t(), map(), opts()) :: {:ok, String.t()} | {:error, Error.t()}

  @doc "The provider's customer portal: returns its URL."
  @callback portal(Context.t(), %{customer_id: String.t(), return_url: String.t()}, opts()) ::
              {:ok, String.t()} | {:error, Error.t()}

  @doc "Cancels at the provider (at period end, or now); returns the subscription as it is now."
  @callback cancel(Context.t(), struct(), boolean(), opts()) :: {:ok, map()} | {:error, Error.t()}

  @doc """
  Switches the subscription to `price_id` (a plan's `id`, `annual_id` or
  `no_trial_id`) at the provider, with its proration rules; returns the
  subscription as the provider has it now. A change the provider schedules
  for later shows up then, in a webhook.
  """
  @callback change_plan(Context.t(), struct(), price_id :: String.t(), opts()) ::
              {:ok, map()} | {:error, Error.t()}

  @doc "Undoes a cancel scheduled for the period's end; returns the subscription as it is now."
  @callback resume(Context.t(), struct(), opts()) :: {:ok, map()} | {:error, Error.t()}

  @optional_callbacks change_plan: 4, resume: 3

  @doc "Checks a webhook (raw body, headers) and returns the subscriptions it reports."
  @callback webhook(Context.t(), binary(), %{String.t() => String.t()}, opts()) ::
              {:ok, [map()]} | {:error, atom()}
end
