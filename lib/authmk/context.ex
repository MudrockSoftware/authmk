defmodule Authmk.Context do
  @moduledoc """
  Everything an endpoint, hook or callback needs about the current request.

  * `config`: the auth module's `Authmk.Config`
  * `conn`: the `Plug.Conn`, or `nil` for calls made from server code
  * `endpoint`: the `Authmk.Endpoint` being served, or `nil`
  * `params`: validated params, with atom keys
  * `raw_params`: params as received, with string keys
  * `session` and `user`: the signed-in session and user, when loaded
  * `resp_cookies`: cookies to set or delete on the response
  """

  alias Authmk.Config

  defstruct [
    :config,
    :conn,
    :endpoint,
    :session,
    :user,
    params: %{},
    raw_params: %{},
    resp_cookies: []
  ]

  @type t :: %__MODULE__{}

  @doc "A context for server-side calls, without a request."
  @spec new(Config.t()) :: t()
  def new(config), do: %__MODULE__{config: config}

  @doc "Sets a cookie on the response."
  @spec put_cookie(t(), String.t(), String.t(), keyword()) :: t()
  def put_cookie(ctx, name, value, opts),
    do: %{ctx | resp_cookies: ctx.resp_cookies ++ [{name, value, opts}]}

  @doc "Deletes a cookie on the response."
  @spec delete_cookie(t(), String.t(), keyword()) :: t()
  def delete_cookie(ctx, name, opts),
    do: %{ctx | resp_cookies: ctx.resp_cookies ++ [{name, :delete, opts}]}

  @doc "Options of `plugin`, as returned by its `init/1`."
  @spec plugin_opts(t(), module()) :: keyword()
  def plugin_opts(%__MODULE__{config: config}, plugin) do
    case List.keyfind(config.plugins, plugin, 0) do
      {^plugin, opts} -> opts
      nil -> raise ArgumentError, "#{inspect(plugin)} is not enabled"
    end
  end
end
