defmodule Authmk.Plugins.OneTimeToken do
  @moduledoc """
  One-time tokens: hand a signed-in user over to another app or domain.

      use Authmk, plugins: [Authmk.Plugins.OneTimeToken], ...

  The signed-in user gets a token (`GET /one-time-token/generate`, or
  `generate/2` from your server), passes it to the other side, which trades
  it at `POST /one-time-token/verify` for a session of its own. Tokens work
  once, expire after `expires_in` seconds, and are stored hashed.

  The new session is a fresh one, so the two sides sign out independently.
  It comes as the session cookie, or, with `disable_set_session_cookie: true`,
  as a `token` in the answer (for `Authorization: Bearer` with
  `Authmk.Plugins.Bearer`).

  ## Options

    * `:expires_in` - seconds (default 180)
    * `:generate_token` - makes tokens; must be unguessable
    * `:disable_client_request` - only `generate/2` makes tokens: no endpoint
    * `:disable_set_session_cookie` - answer with the session token instead
  """

  use Authmk.Plugin

  alias Authmk.{
    Context,
    Cookies,
    Endpoint,
    Error,
    Serializer,
    Sessions,
    Store,
    Token,
    Verification
  }

  @purpose "one-time-token"

  @impl true
  def init(opts) do
    NimbleOptions.validate!(opts,
      expires_in: [type: :pos_integer, default: 180],
      generate_token: [type: {:fun, 0}],
      disable_client_request: [type: :boolean, default: false],
      disable_set_session_cookie: [type: :boolean, default: false]
    )
  end

  @impl true
  def endpoints(opts) do
    generate =
      Endpoint.new(
        name: :generate_one_time_token,
        method: :get,
        path: "/one-time-token/generate",
        handler: {__MODULE__, :generate_endpoint},
        session: :required
      )

    verify =
      Endpoint.new(
        name: :verify_one_time_token,
        method: :post,
        path: "/one-time-token/verify",
        handler: {__MODULE__, :verify},
        rate_limit: [window: 60, max: 10],
        params: [token: [type: :string, required: true]]
      )

    if opts[:disable_client_request], do: [verify], else: [generate, verify]
  end

  @doc "A token for `user_id`, from your server code."
  @spec generate(module(), term()) :: {:ok, String.t()} | {:error, Error.t()}
  def generate(auth, user_id), do: auth.config() |> Context.new() |> create(user_id)

  @doc false
  def generate_endpoint(%Context{user: user} = ctx) do
    with {:ok, token} <- create(ctx, user.id), do: {:ok, %{token: token}, ctx}
  end

  @doc false
  def verify(%Context{params: params} = ctx) do
    opts = opts(ctx)

    with {:ok, %{"user_id" => user_id}} <- Verification.consume(ctx, @purpose, params.token),
         %{} = user <- Store.get_by(ctx, :user, id: user_id),
         {:ok, signed_in} <- Sessions.create(ctx, user) do
      body = %{
        session: Serializer.session(signed_in, signed_in.session),
        user: Serializer.user(signed_in, user)
      }

      if opts[:disable_set_session_cookie],
        do: {:ok, Map.put(body, :token, signed_session_token(signed_in)), ctx},
        else: {:ok, body, signed_in}
    else
      _invalid -> {:error, Error.new(:invalid_token)}
    end
  end

  defp create(ctx, user_id) do
    opts = opts(ctx)
    token = if opts[:generate_token], do: opts[:generate_token].(), else: Token.generate()

    Verification.create(
      ctx,
      @purpose,
      %{"user_id" => to_string(user_id)},
      opts[:expires_in],
      token
    )
  end

  # The signed token of the session just created: what its cookie would hold.
  defp signed_session_token(%Context{resp_cookies: cookies} = ctx) do
    name = Cookies.name(ctx, :session_token)
    {^name, signed, _opts} = List.keyfind(cookies, name, 0)
    signed
  end

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)
end
