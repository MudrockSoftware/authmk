defmodule PlugApp.SMS do
  @moduledoc """
  Sends text messages. Replace `deliver/2` with your SMS provider (Twilio,
  Vonage, ...). In development it logs the message; in tests it sends it to
  the test process, like Swoosh's test adapter.
  """

  @behaviour Authmk.SMS

  require Logger

  @impl Authmk.SMS
  def deliver(to, text, _opts) do
    case Application.get_env(:plug_app, __MODULE__)[:adapter] do
      :test -> send(self(), {:sms, to, text})
      _log -> Logger.info("SMS to #{to}: #{text}")
    end

    :ok
  end
end
