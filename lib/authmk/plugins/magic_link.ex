defmodule Authmk.Plugins.MagicLink do
  @moduledoc """
  Sign in with a link sent by email. Unknown emails sign up (unless
  `disable_sign_up: true`).

      use Authmk,
        plugins: [{Authmk.Plugins.MagicLink, send_magic_link: &MyApp.Auth.send_magic_link/2}],
        ...

  | Method | Path | Session |
  |---|---|---|
  | POST | `/sign-in/magic-link` | none |
  | GET | `/magic-link/verify` | none |

  `POST /sign-in/magic-link` takes `email`, an optional `name` for new users,
  and `callback_url`, `new_user_callback_url` and `error_callback_url`. It
  always answers the same way, so it doesn't reveal who has an account.

  The link opens `GET /magic-link/verify`, which signs the user in (their
  email is verified now) and redirects to `callback_url`; errors go to
  `error_callback_url` as `?error=<code>`. Without a `callback_url` it
  answers with JSON instead. Links work once and expire after `expires_in`
  seconds. Two-factor authentication applies.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.MagicLink.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{
    Background,
    Context,
    Email,
    Endpoint,
    Error,
    Origin,
    Serializer,
    Sessions,
    Store,
    Token,
    URL,
    Verification
  }

  alias Authmk.Plugins.MagicLink.Options

  @purpose "magic-link"

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def endpoints(_opts) do
    callbacks = [
      callback_url: [type: :string],
      new_user_callback_url: [type: :string],
      error_callback_url: [type: :string]
    ]

    [
      Endpoint.new(
        name: :sign_in_magic_link,
        method: :post,
        path: "/sign-in/magic-link",
        handler: {__MODULE__, :send_link},
        rate_limit: [window: 60, max: 5],
        params: [email: [type: :string, required: true], name: [type: :string]] ++ callbacks
      ),
      Endpoint.new(
        name: :magic_link_verify,
        method: :get,
        path: "/magic-link/verify",
        handler: {__MODULE__, :verify},
        params: [token: [type: :string, required: true]] ++ callbacks
      )
    ]
  end

  @doc false
  def send_link(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = Email.normalize(params.email)

    with :ok <- check_redirects(ctx),
         :ok <- valid_email(email) do
      if opts[:disable_sign_up] and is_nil(Store.get_by(ctx, :user, email: email)),
        do: {:ok, %{status: true}, ctx},
        else: send_to(ctx, email, opts)
    end
  end

  @doc false
  def verify(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)

    with :ok <- check_redirects(ctx),
         {:ok, data} <- Verification.consume(ctx, @purpose, params.token),
         {:ok, user, status} <- find_or_sign_up(ctx, data, opts),
         {:ok, user} <- mark_verified(ctx, user) do
      sign_in(ctx, user, status)
    else
      {:error, %Error{code: :invalid_callback_url} = error} -> {:error, error}
      {:error, error} -> fail(ctx, error)
    end
  end

  defp send_to(%Context{params: params} = ctx, email, opts) do
    token = if opts[:generate_token], do: opts[:generate_token].(email), else: Token.generate()
    data = %{"email" => email, "name" => params.name}

    with {:ok, token} <- Verification.create(ctx, @purpose, data, opts[:expires_in], token) do
      url =
        URL.endpoint(ctx, "/magic-link/verify",
          token: token,
          callback_url: params.callback_url,
          new_user_callback_url: params.new_user_callback_url,
          error_callback_url: params.error_callback_url
        )

      link = %{email: email, url: url, token: token}
      Background.run(ctx, fn -> opts[:send_magic_link].(link, ctx) end)
      {:ok, %{status: true}, ctx}
    end
  end

  defp find_or_sign_up(ctx, %{"email" => email} = data, opts) do
    case Store.get_by(ctx, :user, email: email) do
      %{} = user -> {:ok, user, :existing}
      nil -> sign_up(ctx, data, opts[:disable_sign_up])
    end
  end

  defp sign_up(_ctx, _data, true = _disabled), do: {:error, Error.new(:sign_up_disabled)}

  defp sign_up(ctx, %{"email" => email} = data, false) do
    name = data["name"] || email |> String.split("@") |> hd()

    with {:ok, user} <-
           Store.insert(ctx, :user, %{email: email, name: name, email_verified: true}) do
      {:ok, user, :new}
    end
  end

  # Opening the link proves the address.
  defp mark_verified(_ctx, %{email_verified: true} = user), do: {:ok, user}
  defp mark_verified(ctx, user), do: Store.update(ctx, :user, user, %{email_verified: true})

  defp sign_in(%Context{params: params} = ctx, user, status) do
    destination =
      if status == :new,
        do: params.new_user_callback_url || params.callback_url,
        else: params.callback_url

    case Sessions.sign_in(ctx, user) do
      {:ok, ctx} when is_nil(destination) -> {:ok, %{user: Serializer.user(ctx, user)}, ctx}
      {:ok, ctx} -> {:redirect, destination, ctx}
      {:challenge, %{redirect_url: url}, ctx} when is_binary(url) -> {:redirect, url, ctx}
      {:challenge, body, ctx} when is_nil(destination) -> {:ok, body, ctx}
      {:challenge, _body, ctx} -> fail(ctx, Error.new(:additional_verification_required))
      {:error, error} -> fail(ctx, error)
    end
  end

  # Redirect flows can't answer with JSON: the user is in the browser.
  defp fail(%Context{params: params} = ctx, error) do
    case params.error_callback_url || params.callback_url do
      nil -> {:error, error}
      url -> {:redirect, URL.append_query(url, error: error.code), ctx}
    end
  end

  defp check_redirects(%Context{params: params} = ctx) do
    [params.callback_url, params.new_user_callback_url, params.error_callback_url]
    |> Enum.find_value(:ok, fn url ->
      case Origin.check_redirect(ctx, url) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp valid_email(email) do
    if Email.valid?(email), do: :ok, else: {:error, Error.new(:invalid_email)}
  end
end
