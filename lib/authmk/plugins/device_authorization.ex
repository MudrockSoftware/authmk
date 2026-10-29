defmodule Authmk.Plugins.DeviceAuthorization do
  @moduledoc """
  Device authorization (RFC 8628): sign in on a TV, a console or a CLI by
  approving it from a phone or a computer.

      use Authmk, plugins: [Authmk.Plugins.EmailPassword, {Authmk.Plugins.DeviceAuthorization, verification_uri: "https://example.com/device"}], ...

  1. The device asks for codes: `POST /device/code` with `client_id` (and
     `scope`). It shows the `user_code` and the `verification_uri`.
  2. The user opens that page in a browser where they're signed in, enters
     the code (look it up with `GET /device?user_code=...`), and approves
     (`POST /device/approve`) or denies (`POST /device/deny`).
  3. Meanwhile the device polls `POST /device/token` with `grant_type`
     `urn:ietf:params:oauth:grant-type:device_code`, its `device_code` and
     `client_id`, every `interval` seconds, until it gets an `access_token`.

  The token endpoint answers like OAuth: `authorization_pending`,
  `slow_down` (polling too fast adds 5 seconds to the interval),
  `expired_token`, `access_denied`, `invalid_grant` or `invalid_client`,
  with status 400. Device codes are stored hashed and work once. User codes
  use letters that can't be mistaken for each other.

  The access token is a session token (for `Authorization: Bearer` with
  `Authmk.Plugins.Bearer`), or with `token_type: :jwt` a JWT from
  `Authmk.Plugins.JWT`. `create/3` makes codes from your server, optionally
  bound to one user, who alone may approve them.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.DeviceAuthorization.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{Context, Endpoint, Error, Sessions, Store, Token}
  alias Authmk.Plugins.DeviceAuthorization.Options
  alias Authmk.Plugins.JWT

  @grant_type "urn:ietf:params:oauth:grant-type:device_code"
  # No vowels (no words), no look-alikes.
  @user_code_alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def schema(_opts) do
    %{
      device_code: [
        plural: "device_codes",
        fields: [
          # SHA-256 of the device code.
          device_code: [
            type: :string,
            required: true,
            unique: true,
            returned: false,
            input: false
          ],
          user_code: [type: :string, required: true, unique: true, input: false],
          client_id: [type: :string, required: true, input: false],
          scope: [type: :string, input: false],
          status: [type: :string, required: true, default: "pending", input: false],
          # Who approved or denied; or, set in advance, who alone may.
          user_id: [references: :user, on_delete: :delete_all, input: false],
          expires_at: [type: :datetime, required: true, input: false],
          last_polled_at: [type: :datetime, input: false],
          polling_interval: [type: :integer, required: true, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    user_code = [user_code: [type: :string, required: true]]

    [
      endpoint(:device_code, :post, "/device/code", :code,
        rate_limit: [window: 60, max: 10],
        params: [client_id: [type: :string, required: true], scope: [type: :string]]
      ),
      endpoint(:device_token, :post, "/device/token", :token,
        # Checked by the handler, so missing ones get OAuth's invalid_request.
        params: [
          grant_type: [type: :string],
          device_code: [type: :string],
          client_id: [type: :string]
        ]
      ),
      endpoint(:device_verify, :get, "/device", :lookup,
        rate_limit: [window: 60, max: 20],
        params: user_code
      ),
      endpoint(:device_approve, :post, "/device/approve", :approve,
        session: :required,
        params: user_code
      ),
      endpoint(:device_deny, :post, "/device/deny", :deny, session: :required, params: user_code)
    ]
  end

  @doc """
  Makes codes from your server. With `user_id:`, only that user may
  approve them. Also takes `scope:`.
  """
  @spec create(module(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create(auth, client_id, opts \\ []) do
    ctx = %{Context.new(auth.config()) | base_url: server_base_url(auth)}
    issue_codes(ctx, client_id, opts[:scope], opts[:user_id])
  end

  @doc false
  def code(%Context{params: params} = ctx) do
    if valid_client?(ctx, params.client_id) do
      case issue_codes(ctx, params.client_id, params.scope, nil) do
        {:ok, body} -> {:ok, body, ctx}
        error -> error
      end
    else
      oauth_error(ctx, "invalid_client")
    end
  end

  @doc false
  def token(%Context{params: params} = ctx) do
    with :ok <-
           check(
             Enum.all?([params.grant_type, params.device_code, params.client_id], &present?/1),
             "invalid_request"
           ),
         :ok <- check(params.grant_type == @grant_type, "unsupported_grant_type"),
         :ok <- check(valid_client?(ctx, params.client_id), "invalid_client"),
         %{} = device <-
           Store.get_by(ctx, :device_code, device_code: Token.hash(params.device_code)),
         :ok <- check(device.client_id == params.client_id, "invalid_grant") do
      poll(ctx, device)
    else
      {:oauth_error, code} -> oauth_error(ctx, code)
      nil -> oauth_error(ctx, "invalid_grant")
    end
  end

  @doc false
  def lookup(%Context{params: params} = ctx) do
    with {:ok, device} <- pending(ctx, params.user_code) do
      {:ok,
       %{
         user_code: display(device.user_code),
         client_id: device.client_id,
         scope: device.scope,
         status: device.status
       }, ctx}
    end
  end

  @doc false
  def approve(ctx), do: decide(ctx, "approved")

  @doc false
  def deny(ctx), do: decide(ctx, "denied")

  # A code bound to a user only takes that user's decision.
  defp decide(%Context{params: params, user: user} = ctx, status) do
    with {:ok, device} <- pending(ctx, params.user_code),
         :ok <- bound_to(device, user),
         {:ok, _device} <-
           Store.update(ctx, :device_code, device, %{status: status, user_id: user.id}) do
      {:ok, %{success: true}, ctx}
    end
  end

  defp bound_to(%{user_id: nil}, _user), do: :ok
  defp bound_to(%{user_id: id}, %{id: id}), do: :ok
  defp bound_to(_device, _user), do: {:error, Error.new(:forbidden)}

  defp poll(ctx, device) do
    now = DateTime.utc_now()

    cond do
      DateTime.before?(device.expires_at, now) -> oauth_error(ctx, "expired_token")
      device.status == "denied" -> oauth_error(ctx, "access_denied")
      device.status == "approved" -> grant(ctx, device)
      too_fast?(device, now) -> slow_down(ctx, device, now)
      true -> pending_poll(ctx, device, now)
    end
  end

  defp too_fast?(%{last_polled_at: nil}, _now), do: false

  defp too_fast?(device, now),
    do: DateTime.diff(now, device.last_polled_at) < device.polling_interval

  defp slow_down(ctx, device, now) do
    attrs = %{polling_interval: device.polling_interval + 5, last_polled_at: now}
    {:ok, _device} = Store.update(ctx, :device_code, device, attrs)
    oauth_error(ctx, "slow_down")
  end

  defp pending_poll(ctx, device, now) do
    {:ok, _device} = Store.update(ctx, :device_code, device, %{last_polled_at: now})
    oauth_error(ctx, "authorization_pending")
  end

  # Used up first, so two polls can't both get a token.
  defp grant(ctx, device) do
    with 1 <- Store.delete_all(ctx, :device_code, id: device.id),
         %{} = user <- Store.get_by(ctx, :user, id: device.user_id),
         {:ok, signed_in} <- Sessions.create(ctx, user, false),
         {:ok, access_token} <- access_token(signed_in) do
      body = %{
        access_token: access_token,
        token_type: "Bearer",
        expires_in: DateTime.diff(signed_in.session.expires_at, DateTime.utc_now()),
        scope: device.scope
      }

      # The device gets the token in the body; no cookie for this request.
      {:json, 200, Map.reject(body, fn {_key, value} -> is_nil(value) end), ctx}
    else
      _gone -> oauth_error(ctx, "invalid_grant")
    end
  end

  defp access_token(%Context{resp_cookies: cookies} = ctx) do
    case opts(ctx)[:token_type] do
      :jwt ->
        JWT.issue(ctx)

      :session ->
        name = Authmk.Cookies.name(ctx, :session_token)
        {^name, signed, _opts} = List.keyfind(cookies, name, 0)
        {:ok, signed}
    end
  end

  defp issue_codes(ctx, client_id, scope, user_id) do
    opts = opts(ctx)

    device_code =
      if opts[:generate_device_code], do: opts[:generate_device_code].(), else: Token.generate()

    user_code =
      normalize(
        if opts[:generate_user_code], do: opts[:generate_user_code].(), else: user_code(opts)
      )

    attrs = %{
      device_code: Token.hash(device_code),
      user_code: user_code,
      client_id: client_id,
      scope: scope,
      status: "pending",
      user_id: user_id,
      expires_at: DateTime.add(DateTime.utc_now(), opts[:expires_in]),
      polling_interval: opts[:interval]
    }

    with {:ok, _device} <- Store.insert(ctx, :device_code, attrs) do
      uri = verification_uri(ctx, opts)

      {:ok,
       %{
         device_code: device_code,
         user_code: display(user_code),
         verification_uri: uri,
         verification_uri_complete:
           uri <> "?user_code=" <> URI.encode_www_form(display(user_code)),
         expires_in: opts[:expires_in],
         interval: opts[:interval]
       }}
    end
  end

  defp pending(ctx, user_code) do
    case Store.get_by(ctx, :device_code, user_code: normalize(user_code)) do
      %{status: "pending"} = device ->
        if DateTime.after?(device.expires_at, DateTime.utc_now()),
          do: {:ok, device},
          else: {:error, error(:expired_user_code)}

      _missing_or_decided ->
        {:error, error(:invalid_user_code)}
    end
  end

  # Bytes from 240 up are skipped: 240 is 12 × 20, so no letter is likelier.
  defp user_code(opts) do
    length = opts[:user_code_length]

    letters =
      (length * 2)
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.filter(&(&1 < 240))
      |> Enum.take(length)

    if length(letters) == length,
      do: letters |> Enum.map(&Enum.at(@user_code_alphabet, rem(&1, 20))) |> List.to_string(),
      else: user_code(opts)
  end

  # Typed codes may have dashes, spaces and lowercase.
  defp normalize(code), do: code |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")

  defp display(code) do
    {first, second} = String.split_at(code, div(String.length(code), 2))
    first <> "-" <> second
  end

  defp verification_uri(%Context{base_url: base_url}, opts) do
    opts[:verification_uri] ||
      URI.parse(base_url) |> Map.merge(%{path: "/device", query: nil}) |> URI.to_string()
  end

  defp valid_client?(ctx, client_id) do
    case opts(ctx)[:validate_client] do
      nil -> true
      validate -> validate.(client_id) == true
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp check(true, _code), do: :ok
  defp check(_false, code), do: {:oauth_error, code}

  defp oauth_error(ctx, code), do: {:json, 400, %{error: code}, ctx}

  defp server_base_url(auth) do
    case Authmk.BaseURL.resolve(auth.config(), nil) do
      {:ok, url} -> url
      _none -> nil
    end
  end

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)

  defp error(:invalid_user_code),
    do: Error.custom(:invalid_user_code, 404, "This code isn't valid")

  defp error(:expired_user_code),
    do: Error.custom(:expired_user_code, 400, "This code has expired")

  defp endpoint(name, method, path, function, opts) do
    Endpoint.new(
      [name: name, method: method, path: path, handler: {__MODULE__, function}] ++ opts
    )
  end
end
