defmodule Authmk.Plugins.Passkey do
  @moduledoc """
  Passkeys (WebAuthn): register them, sign in with them, manage them.

      # mix.exs
      {:wax_, "~> 0.7"}

      use Authmk,
        plugins: [{Authmk.Plugins.Passkey, origin: "https://app.example.com"}],
        ...

  | Method | Path | Session |
  |---|---|---|
  | POST | `/passkey/generate-register-options` | required (optional with `sign_up`) |
  | POST | `/passkey/verify-registration` | required (optional with `sign_up`) |
  | POST | `/passkey/generate-authenticate-options` | optional |
  | POST | `/passkey/verify-authentication` | none |
  | GET | `/passkey/list-user-passkeys` | required |
  | POST | `/passkey/update-passkey` | required |
  | POST | `/passkey/delete-passkey` | required |

  The options endpoints answer with WebAuthn's JSON options, ready for
  `PublicKeyCredential.parseCreationOptionsFromJSON/1` and
  `parseRequestOptionsFromJSON/1`; send back `credential.toJSON()` as
  `response`. Sign-in options without a session have no
  `allowCredentials`, so browsers offer every passkey for the site, including
  in autofill (conditional UI).

  Every challenge works once and expires after `challenge_expires_in`
  seconds. A passkey whose sign-in counter goes backwards is refused: it may
  have been cloned. A passkey that verified the user (PIN, biometrics)
  counts as two factors and skips two-factor authentication; one that didn't
  goes through it like a password.

  Passkeys registered without a `name` are named after their authenticator
  when its AAGUID is known (see `Authmk.Plugins.Passkey.Authenticators`).
  Extension inputs (PRF, largeBlob, credProps) come from the
  `registration_extensions` and `authentication_extensions` options and the
  request's `extensions`; their results stay in the browser.

  With `sign_up: true`, visitors register a passkey before they have an
  account: they send `email` and `name` (and optionally `callback_url`) to
  the registration options, and the account is created when the passkey is.
  Until its owner proves the email, the account has a placeholder,
  `passkey-<random>@<rp_id>`: the email gets a change-email link
  (`send_change_email_verification`), and opening it moves the account to
  the address, verified. So a passkey registered with someone else's email
  never holds their address, and can't keep them from signing up.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.Passkey.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{
    Context,
    Cookies,
    Crypto,
    Email,
    EmailVerification,
    Endpoint,
    Error,
    Origin,
    Serializer,
    Sessions,
    Store,
    Token,
    Verification
  }

  alias Authmk.Plugins.Passkey.{Authenticators, Options, WebAuthn}

  @purpose "passkey"

  @impl true
  def init(opts) do
    unless Code.ensure_loaded?(Wax) do
      raise ArgumentError,
            ~s(Authmk.Plugins.Passkey needs Wax: add {:wax_, "~> 0.7"} to your deps)
    end

    NimbleOptions.validate!(opts, Options.schema())
  end

  @impl true
  def schema(_opts) do
    %{
      passkey: [
        plural: "passkeys",
        fields: [
          user_id: [
            references: :user,
            on_delete: :delete_all,
            required: true,
            index: true,
            input: false
          ],
          name: [type: :string],
          # base64url. Up to 1023 bytes, so it's looked up by its hash.
          credential_id: [type: :text, required: true, input: false],
          credential_id_hash: [
            type: :string,
            required: true,
            unique: true,
            returned: false,
            input: false
          ],
          # The COSE public key, as base64 CBOR.
          public_key: [type: :text, required: true, returned: false, input: false],
          counter: [type: :integer, required: true, default: 0, input: false],
          device_type: [type: :string, input: false],
          backed_up: [type: :boolean, required: true, default: false, input: false],
          transports: [type: :string, input: false],
          aaguid: [type: :string, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(opts) do
    registration_session = if opts[:sign_up], do: :optional, else: :required
    extensions = [extensions: [type: :map]]

    [
      endpoint(
        :passkey_register_options,
        :post,
        "/passkey/generate-register-options",
        :register_options,
        session: registration_session,
        rate_limit: [window: 60, max: 10],
        params:
          extensions ++
            [email: [type: :string], name: [type: :string], callback_url: [type: :string]]
      ),
      endpoint(
        :passkey_verify_registration,
        :post,
        "/passkey/verify-registration",
        :verify_registration,
        session: registration_session,
        params: [response: [type: :map, required: true], name: [type: :string]]
      ),
      endpoint(
        :passkey_authenticate_options,
        :post,
        "/passkey/generate-authenticate-options",
        :authenticate_options,
        session: :optional,
        rate_limit: [window: 60, max: 10],
        params: extensions
      ),
      endpoint(
        :passkey_verify_authentication,
        :post,
        "/passkey/verify-authentication",
        :verify_authentication,
        rate_limit: [window: 10, max: 5],
        params: [
          response: [type: :map, required: true],
          remember_me: [type: :boolean, default: true]
        ]
      ),
      endpoint(:list_passkeys, :get, "/passkey/list-user-passkeys", :list, session: :required),
      endpoint(:update_passkey, :post, "/passkey/update-passkey", :rename,
        session: :required,
        params: [id: [type: :string, required: true], name: [type: :string, required: true]]
      ),
      endpoint(:delete_passkey, :post, "/passkey/delete-passkey", :delete,
        session: :required,
        params: [id: [type: :string, required: true]]
      )
    ]
  end

  @doc false
  def register_options(%Context{user: nil} = ctx), do: sign_up_options(ctx)

  def register_options(%Context{user: user} = ctx) do
    settings = settings(ctx, :registration)
    challenge = WebAuthn.new_registration_challenge(settings)
    data = %{"kind" => "register", "user_id" => to_string(user.id)}

    with {:ok, ctx} <- start(ctx, challenge, data) do
      excluded = Store.all(ctx, :passkey, user_id: user.id)
      handle = to_string(user.id)
      {:ok, WebAuthn.creation_options(challenge, user, handle, excluded, settings), ctx}
    end
  end

  @doc false
  def verify_registration(%Context{params: params} = ctx) do
    with {:ok, data, ctx} <- take(ctx, "register"),
         challenge =
           WebAuthn.new_registration_challenge(settings(ctx, :registration), data["bytes"]),
         {:ok, credential} <- registered(WebAuthn.register(params.response, challenge)),
         :ok <- new_credential(ctx, credential),
         {:ok, user} <- registering_user(ctx, data),
         {:ok, passkey} <- Store.insert(ctx, :passkey, passkey_attrs(ctx, user, credential)),
         :ok <- confirm_email(ctx, user, data) do
      registered_answer(ctx, user, passkey)
    end
  end

  @doc false
  def authenticate_options(%Context{user: user} = ctx) do
    settings = settings(ctx, :authentication)
    challenge = WebAuthn.new_authentication_challenge(settings)
    allowed = if user, do: Store.all(ctx, :passkey, user_id: user.id), else: []

    with {:ok, ctx} <- start(ctx, challenge, %{"kind" => "authenticate"}) do
      {:ok, WebAuthn.request_options(challenge, allowed, settings), ctx}
    end
  end

  @doc false
  def verify_authentication(%Context{params: params} = ctx) do
    with {:ok, data, ctx} <- take(ctx, "authenticate"),
         challenge =
           WebAuthn.new_authentication_challenge(settings(ctx, :authentication), data["bytes"]),
         %{} = passkey <- find_passkey(ctx, params.response["id"]),
         {:ok, credential_id} <- WebAuthn.decode(passkey.credential_id),
         public_key = WebAuthn.decode_key(passkey.public_key),
         {:ok, result} <-
           WebAuthn.authenticate(params.response, credential_id, public_key, challenge),
         :ok <- counter_moved(passkey, result.sign_count),
         {:ok, _passkey} <- Store.update(ctx, :passkey, passkey, %{counter: result.sign_count}) do
      sign_in(ctx, Store.get_by(ctx, :user, id: passkey.user_id), result.user_verified)
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> {:error, invalid_passkey()}
    end
  end

  @doc false
  def list(%Context{user: user} = ctx) do
    passkeys = Store.all(ctx, :passkey, user_id: user.id)
    {:ok, Enum.map(passkeys, &Serializer.record(ctx, :passkey, &1)), ctx}
  end

  @doc false
  def rename(%Context{params: params} = ctx) do
    with {:ok, passkey} <- own_passkey(ctx, params.id),
         {:ok, passkey} <- Store.update(ctx, :passkey, passkey, %{name: params.name}) do
      {:ok, %{passkey: Serializer.record(ctx, :passkey, passkey)}, ctx}
    end
  end

  @doc false
  def delete(%Context{params: params} = ctx) do
    with {:ok, passkey} <- own_passkey(ctx, params.id),
         {:ok, _passkey} <- Store.delete(ctx, :passkey, passkey) do
      {:ok, %{status: true}, ctx}
    end
  end

  # Registration before there is an account: the email must be free.
  defp sign_up_options(%Context{params: params} = ctx) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    email = params.email && Email.normalize(params.email)

    with :ok <- check(opts[:sign_up], Error.new(:unauthorized)),
         :ok <- check(is_binary(email) and Email.valid?(email), Error.new(:invalid_email)),
         :ok <-
           check(is_nil(Store.get_by(ctx, :user, email: email)), Error.new(:user_already_exists)),
         :ok <- Origin.check_redirect(ctx, params.callback_url) do
      settings = settings(ctx, :registration)
      challenge = WebAuthn.new_registration_challenge(settings)
      name = params.name || email |> String.split("@") |> hd()

      data = %{
        "kind" => "register",
        "email" => email,
        "name" => name,
        "callback_url" => params.callback_url
      }

      handle = :crypto.strong_rand_bytes(16)

      with {:ok, ctx} <- start(ctx, challenge, data) do
        user = %{email: email, name: name}
        {:ok, WebAuthn.creation_options(challenge, user, handle, [], settings), ctx}
      end
    end
  end

  # The challenge lives in a single-use verification token; the browser
  # holds the token in a signed cookie.
  defp start(%Context{config: config} = ctx, challenge, data) do
    expires_in = Context.plugin_opts(ctx, __MODULE__)[:challenge_expires_in]
    data = Map.put(data, "bytes", Base.encode64(challenge.bytes))

    with {:ok, token} <- Verification.create(ctx, @purpose, data, expires_in) do
      {:ok,
       Cookies.put(ctx, :passkey_challenge, Crypto.sign(config, @purpose, token), expires_in)}
    end
  end

  defp take(%Context{config: config} = ctx, kind) do
    with signed when is_binary(signed) <- Cookies.get(ctx, :passkey_challenge),
         {:ok, token} <- Crypto.verify(config, @purpose, signed),
         {:ok, %{"kind" => ^kind} = data} <- Verification.consume(ctx, @purpose, token) do
      {:ok, Map.update!(data, "bytes", &Base.decode64!/1),
       Cookies.delete(ctx, :passkey_challenge)}
    else
      _none ->
        {:error,
         Error.custom(:passkey_challenge_expired, 400, "Start again: the passkey request expired")}
    end
  end

  defp registered({:ok, credential}), do: {:ok, credential}
  defp registered(:error), do: {:error, invalid_passkey()}

  defp new_credential(ctx, credential) do
    if Store.get_by(ctx, :passkey, credential_id_hash: id_hash(credential.credential_id)),
      do:
        {:error,
         Error.custom(:passkey_already_registered, 409, "This passkey is already registered")},
      else: :ok
  end

  # The signed-in user who asked, or a new user for a sign-up.
  defp registering_user(%Context{user: user}, %{"user_id" => user_id}) do
    if user && to_string(user.id) == user_id, do: {:ok, user}, else: {:error, invalid_passkey()}
  end

  defp registering_user(ctx, %{"name" => name}),
    do: Store.insert(ctx, :user, %{email: placeholder_email(ctx), name: name})

  # A new account gets its email once the link sent there is opened. An
  # address taken in the meantime gets nothing.
  defp confirm_email(ctx, user, %{"email" => email, "callback_url" => callback_url}) do
    if Store.get_by(ctx, :user, email: email),
      do: :ok,
      else: EmailVerification.send_change_email(ctx, user, email, callback_url)
  end

  defp confirm_email(_ctx, _user, _data), do: :ok

  defp placeholder_email(ctx) do
    random = 10 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
    "passkey-#{random}@#{settings(ctx, :registration).rp_id}"
  end

  defp registered_answer(%Context{user: nil} = ctx, user, passkey) do
    with {:ok, ctx} <- Sessions.sign_in(ctx, user) do
      {:ok,
       %{passkey: Serializer.record(ctx, :passkey, passkey), user: Serializer.user(ctx, user)},
       ctx}
    end
  end

  defp registered_answer(ctx, _user, passkey),
    do: {:ok, %{passkey: Serializer.record(ctx, :passkey, passkey)}, ctx}

  defp passkey_attrs(%Context{params: params} = ctx, user, credential) do
    names = Context.plugin_opts(ctx, __MODULE__)[:authenticator_names]

    %{
      user_id: user.id,
      name: params.name || Authenticators.name(credential.aaguid, names),
      credential_id: WebAuthn.encode(credential.credential_id),
      credential_id_hash: id_hash(credential.credential_id),
      public_key: WebAuthn.encode_key(credential.public_key),
      counter: credential.sign_count,
      device_type: if(credential.backup_eligible, do: "multi_device", else: "single_device"),
      backed_up: credential.backed_up,
      transports: if(credential.transports != [], do: Enum.join(credential.transports, ",")),
      aaguid: credential.aaguid
    }
  end

  defp find_passkey(ctx, encoded_id) do
    with {:ok, credential_id} <- WebAuthn.decode(encoded_id) do
      Store.get_by(ctx, :passkey, credential_id_hash: id_hash(credential_id))
    end
  end

  # Authenticators that count signatures must count up; 0 means they don't count.
  defp counter_moved(%{counter: 0}, 0), do: :ok
  defp counter_moved(%{counter: stored}, new) when new > stored, do: :ok

  defp counter_moved(_passkey, _new),
    do: {:error, Error.custom(:passkey_cloned, 401, "This passkey may have been copied")}

  # A passkey that verified the user is two factors on its own.
  defp sign_in(%Context{params: params} = ctx, user, true = _user_verified) do
    with {:ok, ctx} <- Sessions.create(ctx, user, params.remember_me) do
      {:ok, %{user: Serializer.user(ctx, user)}, ctx}
    end
  end

  defp sign_in(%Context{params: params} = ctx, user, false) do
    case Sessions.sign_in(ctx, user, params.remember_me) do
      {:ok, ctx} -> {:ok, %{user: Serializer.user(ctx, user)}, ctx}
      {:challenge, body, ctx} -> {:ok, body, ctx}
      {:error, error} -> {:error, error}
    end
  end

  defp own_passkey(%Context{user: user} = ctx, id) do
    case Store.get_by(ctx, :passkey, id: id, user_id: user.id) do
      nil -> {:error, Error.custom(:passkey_not_found, 404, "Passkey not found")}
      passkey -> {:ok, passkey}
    end
  rescue
    Ecto.Query.CastError -> {:error, Error.custom(:passkey_not_found, 404, "Passkey not found")}
  end

  defp settings(%Context{config: config, base_url: base_url, params: params} = ctx, ceremony) do
    opts = Context.plugin_opts(ctx, __MODULE__)
    origin = opts[:origin] || base_origin(base_url)

    defaults =
      opts[
        if(ceremony == :registration,
          do: :registration_extensions,
          else: :authentication_extensions
        )
      ]

    %{
      origin: origin,
      rp_id: opts[:rp_id] || origin |> List.wrap() |> hd() |> URI.parse() |> Map.fetch!(:host),
      rp_name: opts[:rp_name] || config.app_name,
      user_verification: opts[:user_verification],
      timeout: opts[:challenge_expires_in],
      extensions: Map.merge(defaults, Map.get(params, :extensions) || %{})
    }
  end

  defp base_origin(base_url) do
    uri = URI.parse(base_url)
    port = if uri.port in [80, 443], do: "", else: ":#{uri.port}"
    "#{uri.scheme}://#{uri.host}#{port}"
  end

  defp id_hash(credential_id), do: Token.hash(credential_id)

  defp invalid_passkey, do: Error.custom(:invalid_passkey, 401, "This passkey isn't valid here")

  defp check(true, _error), do: :ok
  defp check(_false, error), do: {:error, error}

  defp endpoint(name, method, path, function, opts) do
    Endpoint.new(
      [name: name, method: method, path: path, handler: {__MODULE__, function}] ++ opts
    )
  end
end
