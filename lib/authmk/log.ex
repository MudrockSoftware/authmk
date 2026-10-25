defmodule Authmk.Log do
  @moduledoc """
  authmk's log messages. They all carry the `domain: [:authmk]` metadata,
  so you can silence or redirect them with standard Logger filters:

      # In Application.start/2: drop authmk's logs entirely
      :logger.add_primary_filter(:no_authmk, {&:logger_filters.domain/2, {:stop, :sub, [:authmk]}})

  Levels follow your Logger configuration.
  """

  require Logger

  # `domain` is standard OTP logger metadata for filtering, not a key meant
  # for the console format, so Credo's metadata check doesn't apply.

  @doc false
  # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
  def warning(message), do: Logger.warning(message, domain: [:authmk])

  @doc false
  # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
  def error(message), do: Logger.error(message, domain: [:authmk])
end
