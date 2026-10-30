defmodule Authmk.Branding do
  @moduledoc """
  The app's name, logo and colour on the pages and emails authmk makes
  (the sign-in error page and `Authmk.Emails`).

  Branding starts from the config's `app_name`. A plugin brands the app by
  implementing `c:Authmk.Plugin.branding/1`: the first plugin that returns a
  map wins, field by field, and a `nil` field keeps the default.

  Every value is checked here again, and an invalid one is dropped:

    * `app_name` is trimmed. Blank, longer than 100 characters or with
      control characters, it falls back to the config's.
    * `primary_color` must be `#rrggbb`. It is lowercased.
    * `logo_url` must be an `https://` URL, an `http://` URL on localhost,
      or a path on your site, like `"/images/logo.svg"` (not `//host`).

  `primary_content_color` is computed: `"#000000"` or `"#ffffff"`, whichever
  contrasts more with `primary_color` (WCAG), for text on buttons.

  Where the logo shows:

    * authmk's pages load images only from their own origin (their
      Content-Security-Policy), so they show a path, or a URL on your base
      URL's origin, and leave out a logo hosted elsewhere
      (`page_logo_url/2`).
    * Emails need an absolute URL: a path is made absolute against your base
      URL, and left out when there is none (`email_logo_url/2`).

  A plugin whose `branding/1` raises doesn't break the page or the email:
  authmk logs a warning and uses the defaults.
  """

  alias Authmk.{Context, Hooks, Log, Origin}

  @type t :: %{
          app_name: String.t(),
          logo_url: String.t() | nil,
          primary_color: String.t() | nil,
          primary_content_color: String.t() | nil
        }

  @max_app_name_length 100
  @max_logo_url_length 2048
  @control_characters ~r/[\x00-\x1f\x7f-\x9f]/u
  # Characters no logo URL needs, which browsers may read in surprising
  # ways: control characters, whitespace and backslashes (`/\host`).
  @unsafe_url_characters ~r/[\x00-\x20\x7f-\x9f\\]/u
  @color ~r/\A#[0-9a-fA-F]{6}\z/
  @local_hosts ["localhost", "127.0.0.1", "::1"]

  @doc "The app's branding: the config's, overridden by the first plugin's."
  @spec get(Context.t()) :: t()
  def get(%Context{config: config} = ctx) do
    branding = plugin_branding(ctx)
    primary_color = color(Map.get(branding, :primary_color))

    %{
      app_name: app_name(Map.get(branding, :app_name), config.app_name),
      logo_url: logo_url(Map.get(branding, :logo_url)),
      primary_color: primary_color,
      primary_content_color: content_color(primary_color)
    }
  end

  @doc """
  The logo, when authmk's pages can show it: a path, or a URL on the base
  URL's origin. `nil` otherwise.
  """
  @spec page_logo_url(t(), Context.t()) :: String.t() | nil
  def page_logo_url(%{logo_url: nil}, _ctx), do: nil
  def page_logo_url(%{logo_url: "/" <> _ = path}, _ctx), do: path

  def page_logo_url(%{logo_url: url}, ctx) do
    if Origin.origin(url) == base_origin(ctx), do: url
  end

  @doc """
  The logo as an absolute URL, for emails: a path is made absolute against
  the base URL's origin. `nil` without a logo, or for a path without a base
  URL.
  """
  @spec email_logo_url(t(), Context.t()) :: String.t() | nil
  def email_logo_url(%{logo_url: nil}, _ctx), do: nil

  def email_logo_url(%{logo_url: "/" <> _ = path}, ctx) do
    case base_origin(ctx) do
      nil -> nil
      origin -> origin <> path
    end
  end

  def email_logo_url(%{logo_url: url}, _ctx), do: url

  # A plugin's mistake must not break the page or email that shows it.
  defp plugin_branding(ctx) do
    case Hooks.branding(ctx) do
      %{} = branding -> branding
      _none -> %{}
    end
  rescue
    exception -> defaults_after_failure(inspect(exception.__struct__))
  catch
    :exit, _reason -> defaults_after_failure("exit")
  end

  defp defaults_after_failure(reason) do
    Log.warning("authmk branding: a plugin's branding/1 failed (#{reason}); using the defaults")
    %{}
  end

  defp app_name(name, default) when is_binary(name) do
    name = if String.valid?(name), do: String.trim(name), else: ""

    if name != "" and String.length(name) <= @max_app_name_length and
         not String.match?(name, @control_characters),
       do: name,
       else: default
  end

  defp app_name(_name, default), do: default

  defp color(value) when is_binary(value) do
    if String.match?(value, @color), do: String.downcase(value)
  end

  defp color(_value), do: nil

  defp logo_url(url) when is_binary(url) and byte_size(url) <= @max_logo_url_length do
    if String.valid?(url) and not String.match?(url, @unsafe_url_characters) and
         allowed_logo_url?(url),
       do: url
  end

  defp logo_url(_url), do: nil

  defp allowed_logo_url?("//" <> _), do: false
  defp allowed_logo_url?("/" <> _), do: true

  defp allowed_logo_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when host not in [nil, ""] -> true
      {:ok, %URI{scheme: "http", host: host, userinfo: nil}} when host in @local_hosts -> true
      _other -> false
    end
  end

  # Black or white, whichever contrasts more with the colour (WCAG 2).
  defp content_color(nil), do: nil

  defp content_color(color) do
    luminance = relative_luminance(color)
    contrast_with_white = 1.05 / (luminance + 0.05)
    contrast_with_black = (luminance + 0.05) / 0.05
    if contrast_with_white >= contrast_with_black, do: "#ffffff", else: "#000000"
  end

  defp relative_luminance("#" <> hex) do
    [red, green, blue] =
      for channel <- [0, 2, 4] do
        hex |> binary_part(channel, 2) |> String.to_integer(16) |> linear_channel()
      end

    0.2126 * red + 0.7152 * green + 0.0722 * blue
  end

  defp linear_channel(value) do
    channel = value / 255
    if channel <= 0.04045, do: channel / 12.92, else: :math.pow((channel + 0.055) / 1.055, 2.4)
  end

  defp base_origin(%Context{base_url: nil}), do: nil
  defp base_origin(%Context{base_url: base_url}), do: Origin.origin(base_url)
end
