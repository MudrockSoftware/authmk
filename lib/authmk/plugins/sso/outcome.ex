defmodule Authmk.Plugins.SSO.Outcome do
  @moduledoc false
  # How an SSO sign-in ends, for OpenID Connect and SAML alike: signed in
  # and sent on, or sent to an error page.

  alias Authmk.{Context, Sessions, URL}

  @doc "Signs the user in and sends them on, as the flow's `state` says."
  def complete(ctx, user, status, state) do
    destination =
      if status == :new,
        do: state["new_user_callback_url"] || state["callback_url"],
        else: state["callback_url"]

    case Sessions.sign_in(ctx, user) do
      {:ok, ctx} ->
        {:redirect, destination || "/", ctx}

      {:challenge, %{redirect_url: url}, ctx} when is_binary(url) ->
        {:redirect, url, ctx}

      {:challenge, _body, ctx} ->
        redirect_error(ctx, state["error_callback_url"], :additional_verification_required)

      {:error, error} ->
        redirect_error(ctx, state["error_callback_url"], error.code)
    end
  end

  @doc "Sends the user to the error URL (or authmk's error page) with `code`."
  def redirect_error(%Context{config: config} = ctx, error_url, code) do
    url = error_url || config.errors[:error_url] || URL.endpoint(ctx, "/error")
    {:redirect, URL.append_query(url, error: code), ctx}
  end
end
