defmodule Authmk.Plugins.OpenAPI do
  @moduledoc """
  An OpenAPI 3.1 description of every enabled endpoint, and a reference page
  to browse and try them.

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.OpenAPI], ...

  | Method | Path | Session |
  |---|---|---|
  | GET | `/open-api/generate-schema` | none |
  | GET | `/reference` (`path`) | none |

  Endpoints are grouped by the plugin that adds them (`Core` for authmk's
  own), and the models' public fields are in `components.schemas`. Get the
  description in Elixir with `spec/1`, for client generators or to merge
  with your own API's.

  The reference page runs [Scalar](https://scalar.com) from jsDelivr, pinned
  to one version and checked with Subresource Integrity, so the CDN can't
  swap the code. It has no inline scripts; under a Content Security Policy,
  allow `https://cdn.jsdelivr.net` for scripts, or pass `nonce`. The page
  runs on your auth origin and can call every endpoint as the signed-in
  user. Turn it off with `reference: false` where you don't want that, like
  in production.

  ## Options

    * `:path` - where the reference page is (default `"/reference"`)
    * `:reference` - serve the reference page (default `true`)
    * `:theme` - Scalar's theme (default `"default"`)
    * `:nonce` - CSP nonce for the page's script tag
  """

  use Authmk.Plugin

  alias Authmk.{BaseURL, Context, Endpoint, URL}
  alias Authmk.Plugins.OpenAPI.Generator

  @scalar_url "https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.76.3/dist/browser/standalone.js"
  @scalar_integrity "sha384-H/jJ+XQ0S+5wKmVCrODlHKRKyDzdSBog4sUPc+AQTZddtU1FyQsiCrA47EUte2Fd"

  @impl true
  def init(opts) do
    NimbleOptions.validate!(opts,
      path: [type: :string, default: "/reference"],
      reference: [type: :boolean, default: true],
      theme: [type: :string, default: "default"],
      nonce: [type: :string]
    )
  end

  @impl true
  def endpoints(opts) do
    schema =
      Endpoint.new(
        name: :open_api_schema,
        method: :get,
        path: "/open-api/generate-schema",
        handler: {__MODULE__, :generate_schema}
      )

    reference =
      Endpoint.new(
        name: :open_api_reference,
        method: :get,
        path: opts[:path],
        handler: {__MODULE__, :reference}
      )

    if opts[:reference], do: [schema, reference], else: [schema]
  end

  @doc "The OpenAPI description of `auth`'s endpoints, as a JSON-ready map."
  @spec spec(module()) :: map()
  def spec(auth) do
    config = auth.config()

    base_url =
      case BaseURL.resolve(config, nil) do
        {:ok, base_url} -> base_url
        _dynamic -> nil
      end

    Generator.spec(%{Context.new(config) | base_url: base_url})
  end

  @doc false
  def generate_schema(ctx), do: {:ok, Generator.spec(ctx), ctx}

  @doc false
  def reference(%Context{config: config} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    configuration =
      JSON.encode!(%{
        theme: opts[:theme],
        metaData: %{title: "#{config.app_name} API", description: "Authentication endpoints"}
      })

    nonce = if opts[:nonce], do: ~s( nonce="#{escape(opts[:nonce])}"), else: ""

    html = """
    <!doctype html>
    <html>
      <head>
        <title>#{escape(config.app_name)} API reference</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
      </head>
      <body>
        <script id="api-reference" data-url="#{escape(URL.endpoint(ctx, "/open-api/generate-schema"))}" data-configuration="#{escape(configuration)}"></script>
        <script src="#{@scalar_url}" integrity="#{@scalar_integrity}" crossorigin="anonymous"#{nonce}></script>
      </body>
    </html>
    """

    {:html, 200, html, ctx}
  end

  defp escape(text), do: text |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()
end
