defmodule Authmk.Hooks do
  @moduledoc false
  # Runs endpoint and database hooks: authmk's own (Authmk.CoreHooks), then
  # every plugin in config order, then the auth module itself.

  alias Authmk.{Context, Error}

  @spec before_endpoint(Context.t()) ::
          {:cont, Context.t()} | {:halt, Error.t()} | {:respond, term(), Context.t()}
  def before_endpoint(%Context{} = ctx) do
    name = ctx.endpoint.name

    ctx
    |> hook_modules(:before_endpoint, 2)
    |> Enum.reduce_while({:cont, ctx}, fn module, {:cont, ctx} ->
      case module.before_endpoint(name, ctx) do
        {:cont, %Context{} = ctx} -> {:cont, {:cont, ctx}}
        {:halt, %Error{} = error} -> {:halt, {:halt, error}}
        {:respond, result} -> {:halt, {:respond, result, ctx}}
      end
    end)
  end

  @doc "Runs `on_request/1` hooks, before any built-in check."
  @spec on_request(Context.t()) :: {:cont, Context.t()} | {:halt, Error.t()}
  def on_request(%Context{} = ctx) do
    ctx
    |> hook_modules(:on_request, 1)
    |> Enum.reduce_while({:cont, ctx}, fn module, {:cont, ctx} ->
      case module.on_request(ctx) do
        {:cont, %Context{} = ctx} -> {:cont, {:cont, ctx}}
        {:halt, %Error{} = error} -> {:halt, {:halt, error}}
      end
    end)
  end

  @doc "Runs `on_response/2` hooks on the conn just before it is sent."
  @spec on_response(Plug.Conn.t(), Context.t()) :: Plug.Conn.t()
  def on_response(conn, %Context{} = ctx) do
    ctx
    |> hook_modules(:on_response, 2)
    |> Enum.reduce(conn, fn module, conn -> module.on_response(conn, ctx) end)
  end

  @spec after_endpoint(Context.t(), term()) :: term()
  def after_endpoint(%Context{} = ctx, result) do
    name = ctx.endpoint.name

    ctx
    |> hook_modules(:after_endpoint, 3)
    |> Enum.reduce(result, fn module, result -> module.after_endpoint(name, ctx, result) end)
  end

  @doc "Runs `sign_in_challenge/3` hooks. The first challenge wins."
  @spec sign_in_challenge(Context.t(), struct(), boolean()) ::
          {:cont, Context.t()} | {:challenge, map(), Context.t()} | {:error, Error.t()}
  def sign_in_challenge(%Context{} = ctx, user, remember_me) do
    ctx
    |> hook_modules(:sign_in_challenge, 3)
    |> Enum.reduce_while({:cont, ctx}, fn module, {:cont, ctx} ->
      case module.sign_in_challenge(user, remember_me, ctx) do
        {:cont, %Context{} = ctx} -> {:cont, {:cont, ctx}}
        {:challenge, body, %Context{} = ctx} when is_map(body) -> {:halt, {:challenge, body, ctx}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Runs `authenticate_request/1` hooks. The first that isn't `:none` wins."
  @spec authenticate_request(Context.t()) ::
          {:ok, struct(), struct()}
          | {:principal, term()}
          | {:token, String.t()}
          | :none
          | {:error, Error.t()}
  def authenticate_request(%Context{} = ctx) do
    ctx
    |> hook_modules(:authenticate_request, 1)
    |> Enum.reduce_while(:none, fn module, :none ->
      case module.authenticate_request(ctx) do
        :none -> {:cont, :none}
        {:ok, _session, _user} = signed_in -> {:halt, signed_in}
        {:principal, _principal} = principal -> {:halt, principal}
        {:token, token} when is_binary(token) -> {:halt, {:token, token}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  @doc "Runs `send_email_verification/3` hooks. The first that sends (`:ok`) wins."
  @spec send_email_verification(Context.t(), struct(), String.t() | nil) ::
          :cont | :ok | {:error, Error.t()}
  def send_email_verification(%Context{} = ctx, user, callback_url) do
    ctx
    |> hook_modules(:send_email_verification, 3)
    |> Enum.reduce_while(:cont, fn module, :cont ->
      case module.send_email_verification(user, callback_url, ctx) do
        :cont -> {:cont, :cont}
        :ok -> {:halt, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Runs `:before_*` database hooks. Each may change `data` or stop the write."
  @spec before_write(atom(), atom(), term(), Context.t()) :: {:ok, term()} | {:error, Error.t()}
  def before_write(event, model, data, ctx) do
    ctx
    |> hook_modules(:database_hook, 4)
    |> Enum.reduce_while({:ok, data}, fn module, {:ok, data} ->
      case module.database_hook(event, model, data, ctx) do
        {:ok, data} -> {:cont, {:ok, data}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Runs `:after_*` database hooks. Return values are ignored."
  @spec after_write(atom(), atom(), term(), Context.t()) :: :ok
  def after_write(event, model, record, ctx) do
    for module <- hook_modules(ctx, :database_hook, 4) do
      module.database_hook(event, model, record, ctx)
    end

    :ok
  end

  @doc "Whether any module listens for ended sessions."
  @spec sessions_ended?(Context.t()) :: boolean()
  def sessions_ended?(ctx), do: hook_modules(ctx, :sessions_ended, 3) != []

  @doc "Runs `sessions_ended/3` hooks."
  @spec sessions_ended(Context.t(), term(), [struct()]) :: :ok
  def sessions_ended(_ctx, _user_id, []), do: :ok

  def sessions_ended(ctx, user_id, sessions) do
    ctx
    |> hook_modules(:sessions_ended, 3)
    |> Enum.each(fn module -> :ok = module.sessions_ended(user_id, sessions, ctx) end)
  end

  @doc "Runs `branding/1` hooks. The first that isn't `nil` wins. See `Authmk.Branding`."
  @spec branding(Context.t()) :: map() | nil
  def branding(%Context{} = ctx) do
    ctx
    |> hook_modules(:branding, 1)
    |> Enum.find_value(fn module -> module.branding(ctx) end)
  end

  defp hook_modules(%Context{config: config}, function, arity) do
    Enum.filter(config.hook_modules, &function_exported?(&1, function, arity))
  end
end
