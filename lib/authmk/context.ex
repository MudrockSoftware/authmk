defmodule Authmk.Context do
  @moduledoc """
  Everything an endpoint, hook or callback needs about the current request.

  * `config`: the auth module's `Authmk.Config`
  * `conn`: the `Plug.Conn`, or `nil` for calls made from server code
  * `base_url`: the app's public URL for this request (see `Authmk.BaseURL`)
  * `endpoint`: the `Authmk.Endpoint` being served, or `nil`
  * `params`: validated params, with atom keys
  * `raw_params`: params as received, with string keys
  * `session` and `user`: the signed-in session and user, when loaded
  * `resp_cookies`: cookies to set or delete on the response
  * `private`: data that authmk and plugins pass along within one request
  """

  alias Authmk.Config

  defstruct [
    :config,
    :conn,
    :base_url,
    :endpoint,
    :session,
    :user,
    params: %{},
    raw_params: %{},
    resp_cookies: [],
    private: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  A context for server-side calls, without a request. It has no `base_url`;
  set one (`Authmk.BaseURL.resolve(config, nil)`) before building links.
  """
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

  @doc "Stores a value in `private`."
  @spec put_private(t(), atom(), term()) :: t()
  def put_private(ctx, key, value), do: %{ctx | private: Map.put(ctx.private, key, value)}

  @doc "Options of `plugin`, as returned by its `init/1`."
  @spec plugin_opts(t(), module()) :: keyword()
  def plugin_opts(%__MODULE__{config: config}, plugin) do
    case List.keyfind(config.plugins, plugin, 0) do
      {^plugin, opts} -> opts
      nil -> raise ArgumentError, "#{inspect(plugin)} is not enabled"
    end
  end
end
