defmodule Authmk.OpenTelemetryTest.Auth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.Plugins.EmailPassword],
    base_url: "http://localhost:4000",
    background: :inline,
    rate_limit: [enabled: false]
end

defmodule Authmk.OpenTelemetryTest.Crash do
  @moduledoc false
  use Authmk.Plugin

  @impl true
  def endpoints(_opts),
    do: [
      Authmk.Endpoint.new(name: :boom, method: :get, path: "/boom", handler: {__MODULE__, :boom})
    ]

  def boom(_ctx), do: raise("kaboom")
end

defmodule Authmk.OpenTelemetryTest.CrashAuth do
  use Authmk,
    otp_app: :authmk,
    repo: Authmk.Test.Repo,
    plugins: [Authmk.OpenTelemetryTest.Crash],
    base_url: "http://localhost:4000",
    errors: [rescue: false]
end

defmodule Authmk.OpenTelemetryTest do
  # The span exporter is global: not async.
  use Authmk.EmulationCase, async: false

  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  @moduletag auth: Authmk.OpenTelemetryTest.Auth

  setup do
    # Spans go to this test; after it, to a dead process, which drops them.
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok = Authmk.OpenTelemetry.setup()

    on_exit(fn ->
      :telemetry.detach({Authmk.OpenTelemetry, :endpoint})
      :telemetry.detach({Authmk.OpenTelemetry, :store})
    end)
  end

  test "endpoint requests and their database work become nested spans", %{browser: browser} do
    {_browser, _user} = sign_up(browser)

    endpoint = receive_span("authmk sign_up_email")
    insert = receive_span("authmk.store user insert")

    assert attribute(endpoint, :"authmk.result") == "ok"
    assert attribute(endpoint, :"authmk.auth") == inspect(Authmk.OpenTelemetryTest.Auth)
    assert span(insert, :parent_span_id) == span(endpoint, :span_id)
  end

  test "errors are recorded on the span", %{browser: browser} do
    {_browser, _conn} =
      post(browser, "/sign-in/email", %{email: "nobody@example.com", password: "whatever1"})

    endpoint = receive_span("authmk sign_in_email")
    assert attribute(endpoint, :"authmk.result") == "error"
  end

  # With errors: [rescue: false], crashes leave the endpoint span as exceptions.
  @tag auth: Authmk.OpenTelemetryTest.CrashAuth
  test "crashes mark the span as an error, with the exception", %{browser: browser} do
    assert_raise RuntimeError, fn -> get(browser, "/boom") end

    endpoint = receive_span("authmk boom")
    assert {:status, :error, message} = span(endpoint, :status)
    assert message =~ "kaboom"
  end

  defp receive_span(name) do
    receive do
      {:span, span(name: ^name) = span} -> span
    after
      1000 -> flunk("no span named #{name}")
    end
  end

  defp attribute(span, key) do
    span |> span(:attributes) |> :otel_attributes.map() |> Map.get(key)
  end
end
