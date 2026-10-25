if Code.ensure_loaded?(OpentelemetryTelemetry) do
  defmodule Authmk.OpenTelemetry do
    @moduledoc """
    Turns authmk's telemetry events into OpenTelemetry spans. Add
    `opentelemetry_api` and `opentelemetry_telemetry` to your deps, then call
    this once when your app starts:

        Authmk.OpenTelemetry.setup()

    Spans:

      * `authmk <endpoint>` for every auth endpoint request, with
        `authmk.auth`, `authmk.endpoint` and `authmk.result` attributes
      * `authmk.store <model> <operation>` for every database operation,
        nested under the request's span

    Crashes mark their span as errors, with the exception recorded.
    """

    @tracer_id __MODULE__

    @doc "Attaches the telemetry handlers. Safe to call more than once."
    @spec setup() :: :ok
    def setup do
      for {kind, prefix} <- [endpoint: [:authmk, :endpoint], store: [:authmk, :store]] do
        _ = :telemetry.detach({__MODULE__, kind})
        events = [prefix ++ [:start], prefix ++ [:stop], prefix ++ [:exception]]
        :ok = :telemetry.attach_many({__MODULE__, kind}, events, &__MODULE__.handle_event/4, kind)
      end

      :ok
    end

    @doc false
    def handle_event([:authmk, _source, :start], %{system_time: start_time}, metadata, kind) do
      opts = %{start_time: start_time, attributes: attributes(kind, metadata)}

      _ctx =
        OpentelemetryTelemetry.start_telemetry_span(
          @tracer_id,
          span_name(kind, metadata),
          metadata,
          opts
        )

      :ok
    end

    def handle_event([:authmk, _source, :stop], _measurements, metadata, _config) do
      _ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

      if result = metadata[:result] do
        OpenTelemetry.Tracer.set_attribute(:"authmk.result", Atom.to_string(result))
      end

      OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
    end

    def handle_event([:authmk, _source, :exception], _measurements, metadata, _config) do
      ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)
      %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata

      OpenTelemetry.Span.record_exception(
        ctx,
        Exception.normalize(kind, reason, stacktrace),
        stacktrace
      )

      OpenTelemetry.Tracer.set_status(
        OpenTelemetry.status(:error, Exception.format_banner(kind, reason))
      )

      OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
    end

    defp span_name(:endpoint, metadata), do: "authmk #{metadata.endpoint}"
    defp span_name(:store, metadata), do: "authmk.store #{metadata.model} #{metadata.operation}"

    defp attributes(:endpoint, metadata),
      do: %{
        "authmk.auth": inspect(metadata.auth),
        "authmk.endpoint": Atom.to_string(metadata.endpoint)
      }

    defp attributes(:store, metadata) do
      %{
        "authmk.auth": inspect(metadata.auth),
        "authmk.model": Atom.to_string(metadata.model),
        "authmk.operation": Atom.to_string(metadata.operation)
      }
    end
  end
end
