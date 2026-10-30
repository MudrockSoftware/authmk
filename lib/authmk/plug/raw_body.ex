defmodule Authmk.Plug.RawBody do
  @moduledoc """
  Keeps the request body as it arrived, for webhooks: payment providers
  sign the exact bytes they send, so the signature can only be checked
  against those, not against parsed params.

  authmk's router reads bodies this way itself. When your endpoint parses
  bodies before authmk sees them (Phoenix does, in `endpoint.ex`), give its
  parser this reader:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        body_reader: {Authmk.Plug.RawBody, :read_body, []},
        json_decoder: Phoenix.json_library()

  Without it, authmk's webhooks refuse every request (the signature can't
  be checked), with an error saying so.
  """

  @doc "A `Plug.Parsers` body reader that keeps the body in `conn.private[:authmk_raw_body]`."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        kept = (conn.private[:authmk_raw_body] || "") <> body
        {status, body, Plug.Conn.put_private(conn, :authmk_raw_body, kept)}

      error ->
        error
    end
  end

  @doc "The body this reader kept, or `nil`."
  @spec get(Plug.Conn.t()) :: binary() | nil
  def get(conn), do: conn.private[:authmk_raw_body]
end
