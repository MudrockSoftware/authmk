defmodule Authmk.Endpoint do
  @moduledoc """
  An HTTP endpoint served by the auth router. Core and plugins declare
  endpoints with `new/1`:

      Authmk.Endpoint.new(
        name: :sign_in_email,
        method: :post,
        path: "/sign-in/email",
        handler: {MyPlugin, :sign_in},
        params: [email: [type: :string, required: true]],
        rate_limit: [window: 10, max: 3]
      )

  The handler receives an `Authmk.Context` and returns one of:

    * `{:ok, body, ctx}`: JSON response with status 200
    * `{:redirect, url, ctx}`: 302 redirect
    * `{:error, %Authmk.Error{}}` or `{:error, %Authmk.Error{}, ctx}`
  """

  @schema NimbleOptions.new!(
            name: [type: :atom, required: true, doc: "Unique name, used by hooks."],
            method: [type: {:in, [:get, :post]}, required: true],
            path: [type: :string, required: true, doc: "Like `/reset-password/:token`."],
            handler: [type: {:tuple, [:atom, :atom]}, required: true],
            params: [
              type: :keyword_list,
              default: [],
              doc: "Params as `name: [type: ..., required: ..., default: ...]`."
            ],
            session: [
              type: {:in, [:none, :optional, :required]},
              default: :none,
              doc: "Whether to load the session. `:required` rejects anonymous requests."
            ],
            fresh: [type: :boolean, default: false, doc: "Require a recently created session."],
            cookie_cache: [
              type: :boolean,
              default: false,
              doc:
                "Allow reading the session from the cookie cache. Only for read-only endpoints."
            ],
            rate_limit: [
              type: :keyword_list,
              doc: "Default rule: `[window: seconds, max: count]`."
            ],
            plugin: [type: :atom, doc: "Set by authmk to the plugin that declared the endpoint."]
          )

  @enforce_keys [:name, :method, :path, :handler]
  defstruct [
    :name,
    :method,
    :path,
    :handler,
    :rate_limit,
    :plugin,
    params: [],
    session: :none,
    fresh: false,
    cookie_cache: false
  ]

  @type t :: %__MODULE__{}

  @doc "Builds and validates an endpoint."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, NimbleOptions.validate!(opts, @schema))

  @doc """
  Matches a request against the endpoint. Returns the path params, or `:error`.
  """
  @spec match(t(), String.t(), [String.t()]) :: {:ok, map()} | :error
  def match(%__MODULE__{} = endpoint, method, path_info) do
    if method == endpoint.method |> Atom.to_string() |> String.upcase() do
      match_segments(String.split(endpoint.path, "/", trim: true), path_info, %{})
    else
      :error
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | rest], [value | values], params),
    do: match_segments(rest, values, Map.put(params, name, value))

  defp match_segments([segment | rest], [segment | values], params),
    do: match_segments(rest, values, params)

  defp match_segments(_segments, _values, _params), do: :error
end
