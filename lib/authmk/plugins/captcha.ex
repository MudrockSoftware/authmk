defmodule Authmk.Plugins.Captcha do
  @moduledoc """
  Captchas on the endpoints bots like: Cloudflare Turnstile, Google
  reCAPTCHA (v2 and v3), hCaptcha and CaptchaFox.

      use Authmk,
        plugins: [
          Authmk.Plugins.EmailPassword,
          {Authmk.Plugins.Captcha, provider: :turnstile, secret_key: System.fetch_env!("TURNSTILE_SECRET")}
        ],
        ...

  The client sends the widget's token in the `x-captcha-response` header.
  Requests to the protected `endpoints` without it are refused
  (`captcha_required`), and so are those the provider turns down
  (`captcha_failed`) or, with reCAPTCHA v3, that score below `min_score`.
  When the provider can't be reached, the request is refused too
  (`captcha_unavailable`): bots don't get through an outage.

  ## Options

  #{NimbleOptions.docs(Authmk.Plugins.Captcha.Options.schema())}
  """

  use Authmk.Plugin

  alias Authmk.{Context, Error, Request}
  alias Authmk.OAuth.HTTP
  alias Authmk.Plugins.Captcha.Options

  @header "x-captcha-response"

  @verify_urls %{
    turnstile: "https://challenges.cloudflare.com/turnstile/v0/siteverify",
    recaptcha: "https://www.google.com/recaptcha/api/siteverify",
    hcaptcha: "https://api.hcaptcha.com/siteverify",
    captchafox: "https://api.captchafox.com/siteverify"
  }

  @impl true
  def init(opts), do: NimbleOptions.validate!(opts, Options.schema())

  @impl true
  def before_endpoint(endpoint, %Context{conn: conn} = ctx) do
    opts = opts(ctx)

    if endpoint in opts[:endpoints] do
      case Plug.Conn.get_req_header(conn, @header) do
        [token | _] when token != "" -> verify(ctx, opts, token)
        _missing -> {:halt, error(:captcha_required)}
      end
    else
      {:cont, ctx}
    end
  end

  defp verify(ctx, opts, token) do
    form =
      [secret: opts[:secret_key], response: token, remoteip: Request.client_ip(ctx)] ++
        if(opts[:site_key], do: [sitekey: opts[:site_key]], else: [])

    case HTTP.post_form(ctx, opts[:verify_url] || @verify_urls[opts[:provider]], form) do
      {:ok, 200, %{"success" => true} = answer} -> check_score(ctx, opts, answer)
      {:ok, 200, %{"success" => false}} -> {:halt, error(:captcha_failed)}
      _unreachable_or_odd -> {:halt, error(:captcha_unavailable)}
    end
  end

  # reCAPTCHA v3 scores requests from 0 (bot) to 1 (human); v2 has no score.
  defp check_score(ctx, opts, answer) do
    case answer do
      %{"score" => score} when is_number(score) ->
        if score >= opts[:min_score], do: {:cont, ctx}, else: {:halt, error(:captcha_failed)}

      _no_score ->
        {:cont, ctx}
    end
  end

  defp opts(ctx), do: Context.plugin_opts(ctx, __MODULE__)

  defp error(:captcha_required), do: Error.custom(:captcha_required, 400, "Complete the captcha")
  defp error(:captcha_failed), do: Error.custom(:captcha_failed, 403, "The captcha wasn't solved")

  defp error(:captcha_unavailable),
    do: Error.custom(:captcha_unavailable, 503, "The captcha couldn't be checked; try again")
end
