defmodule Authmk.SMS do
  @moduledoc """
  A behaviour for sending text messages, so phone codes can go through any
  provider, and a helper to deliver authmk's codes with one.

      defmodule MyApp.SMS do
        @behaviour Authmk.SMS

        @impl true
        def deliver(to, body, _opts), do: MyApp.Twilio.send(to, body)
      end

      # in your auth module
      {Authmk.Plugins.PhoneNumber, send_otp: &__MODULE__.send_phone_code/2}

      def send_phone_code(message, ctx), do: Authmk.SMS.send_otp(MyApp.SMS, message, ctx)

  `Authmk.SMS.Test` delivers to the test process instead, for tests.
  """

  alias Authmk.Context

  @doc "Sends `body` to the phone number `to` (E.164, like `+15551234567`)."
  @callback deliver(to :: String.t(), body :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Sends one of authmk's codes (`%{phone_number:, code:}` from
  `Authmk.Plugins.PhoneNumber`, or `%{otp:}` with a user's phone) with
  `sender`. The text names the app and the code, nothing else.
  """
  @spec send_otp(module(), map(), Context.t(), keyword()) :: :ok | {:error, term()}
  def send_otp(sender, message, %Context{config: config}, opts \\ []) do
    to = message[:phone_number] || (message[:user] && Map.get(message.user, :phone_number))
    code = message[:code] || message[:otp]
    app = opts[:app_name] || config.app_name

    sender.deliver(to, "#{code} is your #{app} code. Don't share it.", opts)
  end
end
