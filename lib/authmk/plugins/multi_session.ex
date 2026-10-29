defmodule Authmk.Plugins.MultiSession do
  @moduledoc """
  Several signed-in accounts on one device, like switching between a work
  and a personal account.

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.MultiSession, maximum_sessions: 5}], ...

  Every sign-in on the device joins the device's sessions (an encrypted
  cookie); the newest is active. At most `maximum_sessions` are kept: older
  ones are signed out.

  | Method | Path | Session |
  |---|---|---|
  | GET | `/multi-session/list-device-sessions` | none |
  | POST | `/multi-session/set-active` | none |
  | POST | `/multi-session/revoke` | none |

  Sessions are named by their id, so tokens never leave the cookie.
  `POST /sign-out` signs every account on the device out.
  """

  use Authmk.Plugin

  alias Authmk.{Context, Cookies, Crypto, Error, Serializer, SessionStore, Token}

  @purpose "multi-session"

  @impl true
  def init(opts),
    do: NimbleOptions.validate!(opts, maximum_sessions: [type: :pos_integer, default: 5])

  @impl true
  def endpoints(_opts) do
    session_id = [session_id: [type: :string, required: true]]

    [
      endpoint(:list_device_sessions, :get, "/multi-session/list-device-sessions", :list, []),
      endpoint(:set_active_session, :post, "/multi-session/set-active", :set_active, session_id),
      endpoint(:revoke_device_session, :post, "/multi-session/revoke", :revoke, session_id)
    ]
  end

  # New sessions join the device's list; signing out ends them all.
  @impl true
  def after_endpoint(:sign_out, ctx, {:ok, body, result_ctx}) do
    for {_token, session} <- device_sessions(ctx), do: :ok = SessionStore.delete(ctx, session)
    {:ok, body, Cookies.delete(result_ctx, :device_sessions)}
  end

  def after_endpoint(_endpoint, ctx, {:ok, body, %Context{} = result_ctx}),
    do: {:ok, body, remember_new_session(ctx, result_ctx)}

  def after_endpoint(_endpoint, ctx, {:redirect, url, %Context{} = result_ctx}),
    do: {:redirect, url, remember_new_session(ctx, result_ctx)}

  def after_endpoint(_endpoint, _ctx, result), do: result

  @doc false
  def list(ctx) do
    sessions =
      for {_token, session} <- device_sessions(ctx) do
        %{session: Serializer.session(ctx, session), user: Serializer.user(ctx, session.user)}
      end

    {:ok, sessions, ctx}
  end

  @doc false
  def set_active(%Context{params: params} = ctx) do
    case find(ctx, params.session_id) do
      {token, session} ->
        ctx = Cookies.put_session(ctx, token, Cookies.remember_me?(ctx))

        {:ok,
         %{session: Serializer.session(ctx, session), user: Serializer.user(ctx, session.user)},
         ctx}

      nil ->
        {:error, not_found()}
    end
  end

  @doc false
  def revoke(%Context{params: params} = ctx) do
    case find(ctx, params.session_id) do
      {token, session} ->
        :ok = SessionStore.delete(ctx, session)
        remaining = Enum.reject(device_sessions(ctx), fn {other, _session} -> other == token end)
        ctx = put_tokens(ctx, Enum.map(remaining, &elem(&1, 0)))
        {:ok, %{status: true}, switch_if_active(ctx, token, remaining)}

      nil ->
        {:error, not_found()}
    end
  end

  # When the active session goes, the next one takes over (or none).
  defp switch_if_active(ctx, revoked, remaining) do
    if Cookies.session_token(ctx) == {:ok, revoked} do
      case remaining do
        [{token, _session} | _] -> Cookies.put_session(ctx, token, Cookies.remember_me?(ctx))
        [] -> Cookies.clear_session(ctx)
      end
    else
      ctx
    end
  end

  # A session the response just started joins the list (newest first).
  defp remember_new_session(request_ctx, %Context{resp_cookies: cookies, config: config} = ctx) do
    name = Cookies.name(ctx, :session_token)

    with {^name, signed, _opts} when is_binary(signed) <- List.keyfind(cookies, name, 0),
         {:ok, token} <- Crypto.verify(config, "session-token", signed),
         tokens = request_tokens(request_ctx),
         false <- token in tokens do
      {kept, dropped} = Enum.split([token | tokens], opts(ctx)[:maximum_sessions])
      :ok = sign_out_tokens(ctx, dropped)
      put_tokens(ctx, kept)
    else
      _no_new_session -> ctx
    end
  end

  defp sign_out_tokens(ctx, tokens) do
    Enum.each(tokens, fn token ->
      case SessionStore.fetch(ctx, Token.hash(token)) do
        nil -> :ok
        session -> :ok = SessionStore.delete(ctx, session)
      end
    end)
  end

  # The device's live sessions, newest first, as {token, session}.
  defp device_sessions(ctx) do
    Enum.flat_map(request_tokens(ctx), fn token ->
      case live_session(ctx, token) do
        nil -> []
        session -> [{token, session}]
      end
    end)
  end

  defp live_session(ctx, token) do
    with %{} = session <- SessionStore.fetch(ctx, Token.hash(token)),
         true <- DateTime.after?(session.expires_at, DateTime.utc_now()) do
      session
    else
      _gone -> nil
    end
  end

  defp find(ctx, session_id) do
    Enum.find(device_sessions(ctx), fn {_token, session} ->
      to_string(session.id) == session_id
    end)
  end

  defp request_tokens(%Context{config: config} = ctx) do
    with encrypted when is_binary(encrypted) <- Cookies.get(ctx, :device_sessions),
         {:ok, json} <- Crypto.decrypt(config, @purpose, encrypted),
         {:ok, tokens} when is_list(tokens) <- JSON.decode(json) do
      Enum.filter(tokens, &is_binary/1)
    else
      _none -> []
    end
  end

  defp put_tokens(%Context{config: config} = ctx, tokens) do
    value = Crypto.encrypt(config, @purpose, JSON.encode!(tokens))
    Cookies.put(ctx, :device_sessions, value, config.session[:expires_in])
  end

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)

  defp not_found, do: Error.custom(:session_not_found, 404, "No such session on this device")

  defp endpoint(name, method, path, function, params) do
    Authmk.Endpoint.new(
      name: name,
      method: method,
      path: path,
      handler: {__MODULE__, function},
      params: params
    )
  end
end
