defmodule PhoenixApp.SMS do
  @moduledoc """
  Sends text messages. Replace `deliver/2` with your SMS provider (Twilio,
  Vonage, ...). In development it logs the message; in tests it sends it to
  the test process, like Swoosh's test adapter.
  """

  require Logger

  def deliver(to, text) do
    case Application.get_env(:phoenix_app, __MODULE__)[:adapter] do
      :test -> send(self(), {:sms, to, text})
      _log -> Logger.info("SMS to #{to}: #{text}")
    end

    :ok
  end
end
