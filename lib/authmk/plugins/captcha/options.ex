defmodule Authmk.Plugins.Captcha.Options do
  @moduledoc false

  @schema NimbleOptions.new!(
            provider: [
              type: {:in, [:turnstile, :recaptcha, :hcaptcha, :captchafox]},
              required: true
            ],
            secret_key: [type: :string, required: true],
            site_key: [
              type: :string,
              doc: "Sent to providers that check it (hCaptcha, CaptchaFox)."
            ],
            endpoints: [
              type: {:list, :atom},
              default: [:sign_up_email, :sign_in_email, :request_password_reset],
              doc: "Endpoint names that need a captcha."
            ],
            min_score: [
              type: :float,
              default: 0.5,
              doc: "reCAPTCHA v3: the lowest score let through."
            ],
            verify_url: [type: :string, doc: "Overrides the provider's verification URL."]
          )

  def schema, do: @schema
end
