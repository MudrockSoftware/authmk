defmodule Authmk.OAuth.State do
  @moduledoc """
  The data a sign-in flow carries from the redirect to the callback: the
  `state` value, PKCE verifier, ID-token nonce, where to go afterwards, and
  which user to link to.

  With `account: [store_state: :cookie]` (the default) it lives in an
  encrypted cookie. With `:database` it lives in a verification token, and
  the cookie keeps only a signed copy of `state`. Either way, the callback
  must come back to the browser that started the flow, which stops an
  attacker from slipping their own sign-in into someone else's browser.
  Flows expire after 10 minutes.
  """

  alias Authmk.{Context, Cookies, Crypto, Error, Token, Verification}

  @ttl 600
  @cookie_purpose "oauth-state"
  @verification_purpose "oauth-state"

  @doc """
  Starts a flow: returns the context (with the state cookie set), the
  `state` value for the authorization URL, and the stored data, which
  includes `"code_verifier"` and `"nonce"`.
  """
  @spec start(Context.t(), map()) :: {:ok, Context.t(), String.t(), map()} | {:error, Error.t()}
  def start(%Context{config: config} = ctx, data) do
    state = Token.generate()

    data =
      Map.merge(data, %{
        "state" => state,
        "code_verifier" => Token.generate(48),
        "nonce" => Token.generate(16),
        "expires_at" => System.system_time(:second) + @ttl
      })

    case config.account[:store_state] do
      :cookie ->
        cookie = Crypto.encrypt(config, @cookie_purpose, JSON.encode!(data))
        {:ok, Cookies.put_oauth_state(ctx, cookie, @ttl), state, data}

      :database ->
        with {:ok, token} <- Verification.create(ctx, @verification_purpose, data, @ttl, state) do
          cookie = Crypto.sign(config, @cookie_purpose, token)
          {:ok, Cookies.put_oauth_state(ctx, cookie, @ttl), state, data}
        end
    end
  end

  @doc """
  Checks the callback's `state` against this browser's flow and returns its
  data. The flow is used up (its cookie deleted) either way, so errors come
  with the context too.
  """
  @spec finish(Context.t(), String.t() | nil) ::
          {:ok, Context.t(), map()} | {:error, Context.t(), Error.t()}
  def finish(%Context{config: config} = ctx, state) do
    cookie = Cookies.oauth_state(ctx)
    ctx = Cookies.delete(ctx, :oauth_state)

    result =
      cond do
        not is_binary(state) -> {:error, Error.new(:state_not_found)}
        not is_binary(cookie) -> {:error, Error.new(:state_mismatch)}
        true -> read(ctx, config.account[:store_state], cookie, state)
      end

    with {:ok, data} <- result,
         :ok <- check(data, state) do
      {:ok, ctx, data}
    else
      {:error, error} -> {:error, ctx, error}
    end
  end

  defp read(%Context{config: config}, :cookie, cookie, _state) do
    with {:ok, json} <- Crypto.decrypt(config, @cookie_purpose, cookie),
         {:ok, data} <- JSON.decode(json) do
      {:ok, data}
    else
      _ -> {:error, Error.new(:state_mismatch)}
    end
  end

  defp read(%Context{config: config} = ctx, :database, cookie, state) do
    with {:ok, signed_state} <- Crypto.verify(config, @cookie_purpose, cookie),
         true <- Plug.Crypto.secure_compare(signed_state, state),
         {:ok, data} <- Verification.consume(ctx, @verification_purpose, state) do
      {:ok, data}
    else
      _ -> {:error, Error.new(:state_mismatch)}
    end
  end

  defp check(data, state) do
    cond do
      not Plug.Crypto.secure_compare(data["state"] || "", state) ->
        {:error, Error.new(:state_mismatch)}

      data["expires_at"] < System.system_time(:second) ->
        {:error, Error.new(:state_mismatch)}

      true ->
        :ok
    end
  end
end
