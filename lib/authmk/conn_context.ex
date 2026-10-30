defmodule Authmk.ConnContext do
  @moduledoc false
  # A context for a request outside the auth router: a plug, a controller,
  # LiveView's session function. Hosts outside base_url's allow list get
  # no context, so they never get a session.

  alias Authmk.{BaseURL, Config, Context}

  @spec new(Plug.Conn.t(), module()) :: {:ok, Context.t()} | :invalid_host
  def new(conn, auth) do
    conn = Plug.Conn.fetch_cookies(conn)
    config = Config.fetch!(auth)

    case BaseURL.resolve(config, conn) do
      {:ok, base_url} -> {:ok, %Context{config: config, conn: conn, base_url: base_url}}
      {:error, _invalid_host} -> :invalid_host
    end
  end
end
