defmodule Authmk.Test.FakeBilling do
  @moduledoc false
  # A stand-in payment provider's API, behind Req.Test: it keeps
  # subscriptions (so webhooks can be re-read from it), answers with
  # `routes`, and tells the test process about every request.

  @doc """
  Stubs `name`. `routes`: `fn method, path, params, state -> {status, body}`
  (or `:default`). State is an Agent the test can change with put/3.
  """
  def stub(name, routes) do
    test = self()
    {:ok, state} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)

      params =
        case Plug.Conn.get_req_header(conn, "content-type") do
          ["application/json" <> _] when body != "" -> JSON.decode!(body)
          _form -> Map.merge(conn.query_params, URI.decode_query(body))
        end

      send(test, {:billing_request, conn.method, conn.request_path, params, conn.req_headers})
      {status, response} = routes.(conn.method, conn.request_path, params, state)
      Req.Test.json(Plug.Conn.put_status(conn, status), response)
    end)

    state
  end

  def put(state, key, value), do: Agent.update(state, &Map.put(&1, key, value))
  def get(state, key), do: Agent.get(state, &Map.get(&1, key))

  @doc "Posts a webhook to the auth router: the exact `body`, with `headers`."
  def webhook(auth, body, headers) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:post, "/auth/billing/webhook", body), fn {k, v},
                                                                                    conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Plug.forward(conn, ["billing", "webhook"], auth, auth.init([]))
  end

  @doc "Stripe's `Stripe-Signature` for `body`."
  def stripe_signature(body, secret, timestamp \\ System.system_time(:second)) do
    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}") |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  @doc "Standard Webhooks headers for `body`, with the HMAC `key`."
  def standard_headers(body, key, id \\ "msg_1", timestamp \\ System.system_time(:second)) do
    signature = :crypto.mac(:hmac, :sha256, key, "#{id}.#{timestamp}.#{body}") |> Base.encode64()

    [
      {"webhook-id", id},
      {"webhook-timestamp", to_string(timestamp)},
      {"webhook-signature", "v1," <> signature}
    ]
  end
end
