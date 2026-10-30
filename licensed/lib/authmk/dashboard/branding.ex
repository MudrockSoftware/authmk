defmodule Authmk.Dashboard.Branding do
  @moduledoc """
  Custom branding, edited in the dashboard (`Authmk.Dashboard`): the app's
  name, logo and colour, used by the dashboard, authmk's own pages (the
  sign-in error page) and the ready-made emails (`Authmk.Emails`).

      use Authmk,
        plugins: [Authmk.Plugins.EmailPassword, Authmk.Plugins.Admin, Authmk.Dashboard.Branding],
        ...

  Then run `mix authmk.gen.migration`: branding is kept in its own table,
  one row. Admins with the Admin permission `branding: update` change it
  on the dashboard's Branding page; each change is written to the audit
  log. Until then, and for whatever isn't set, the config's `app_name` and
  authmk's look are used.

  The logo (PNG, JPEG, WebP, GIF or SVG, at most 256 KB) is served from
  `<base URL>/branding/logo`, so pages and emails link to it on your own
  site. SVGs are served so that no script in them can run.

  Like the dashboard, this is licensed separately from authmk (see
  `Authmk.License`): without a valid licence key outside development,
  pages and emails keep authmk's look.
  """

  use Authmk.Plugin

  alias Authmk.{Context, Endpoint, Error, License, Log, Store, URL}
  alias Authmk.Storage.ETS

  @cache_key "dashboard-branding"
  @cache_ttl 60
  @max_logo_bytes 256 * 1024
  @color ~r/\A#[0-9a-fA-F]{6}\z/
  @logo_types ~w(image/png image/jpeg image/webp image/gif image/svg+xml)

  @impl true
  def schema(_opts) do
    %{
      branding: [
        plural: "branding",
        fields: [
          app_name: [type: :string, input: false],
          primary_color: [type: :string, input: false],
          # base64, with its type and a hash naming this version.
          logo: [type: :text, input: false],
          logo_type: [type: :string, input: false],
          logo_hash: [type: :string, input: false]
        ]
      ]
    }
  end

  @impl true
  def endpoints(_opts) do
    [
      Endpoint.new(
        name: :branding_logo,
        method: :get,
        path: "/branding/logo",
        handler: {__MODULE__, :logo},
        session: :none,
        origin_check: false
      )
    ]
  end

  @impl true
  def branding(ctx) do
    if License.check() == :ok do
      case cached(ctx) do
        nil -> nil
        settings -> public(ctx, settings)
      end
    end
  end

  @doc false
  # The branding pages, emails and the dashboard use: name, logo URL, colour.
  def public(ctx, settings) do
    %{
      app_name: settings.app_name,
      primary_color: settings.primary_color,
      logo_url: settings.logo_hash && URL.endpoint(ctx, "/branding/logo", v: settings.logo_hash)
    }
  end

  @doc false
  # The stored settings, or nil. Read through a short cache: branding is on
  # every page and email, and a change shows everywhere within a minute.
  def cached(%Context{config: config} = ctx) do
    table = [table: ETS.table(config.auth)]

    case ETS.get(table, @cache_key) do
      nil ->
        settings = load(ctx)
        :ok = ETS.put(table, @cache_key, settings || :none, @cache_ttl)
        settings

      :none ->
        nil

      settings ->
        settings
    end
  end

  defp load(ctx) do
    case Store.all(ctx, :branding, [], limit: 1) do
      [row] ->
        %{
          app_name: row.app_name,
          primary_color: row.primary_color,
          logo_hash: row.logo && row.logo_hash
        }

      [] ->
        nil
    end
  end

  @doc false
  # The settings now, for the dashboard: straight from the database.
  def settings(ctx), do: load(ctx) || %{app_name: nil, primary_color: nil, logo_hash: nil}

  @doc false
  # Saves the dashboard's changes: `app_name`, `primary_color` (`#rrggbb`),
  # and `logo` (`%{"type" => ..., "data" => base64}`, or nil to remove it).
  # Only the keys given change.
  def update(ctx, changes) do
    with {:ok, attrs} <- attrs(changes) do
      result =
        case Store.all(ctx, :branding, [], limit: 1) do
          [row] -> Store.update(ctx, :branding, row, attrs)
          [] -> Store.insert(ctx, :branding, attrs)
        end

      :ok = ETS.delete([table: ETS.table(ctx.config.auth)], @cache_key)
      with {:ok, _row} <- result, do: :ok
    end
  end

  defp attrs(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn {key, value}, {:ok, attrs} ->
      case attr(key, value) do
        {:ok, new} -> {:cont, {:ok, Map.merge(attrs, new)}}
        {:error, message} -> {:halt, {:error, Error.custom(:invalid_branding, 400, message)}}
      end
    end)
  end

  defp attr("app_name", nil), do: {:ok, %{app_name: nil}}

  defp attr("app_name", name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:ok, %{app_name: nil}}
      name when byte_size(name) <= 100 -> {:ok, %{app_name: name}}
      _long -> {:error, "The app's name can be 100 characters at most."}
    end
  end

  defp attr("primary_color", nil), do: {:ok, %{primary_color: nil}}

  defp attr("primary_color", color) when is_binary(color) do
    if Regex.match?(@color, color),
      do: {:ok, %{primary_color: String.downcase(color)}},
      else: {:error, "Colours look like #1d4ed8."}
  end

  defp attr("logo", nil), do: {:ok, %{logo: nil, logo_type: nil, logo_hash: nil}}

  defp attr("logo", %{"type" => type, "data" => data}) when type in @logo_types do
    with {:ok, bytes} <- decode(data),
         :ok <- logo_matches(type, bytes) do
      hash =
        :crypto.hash(:sha256, bytes) |> Base.url_encode64(padding: false) |> binary_part(0, 16)

      {:ok, %{logo: Base.encode64(bytes), logo_type: type, logo_hash: hash}}
    end
  end

  defp attr("logo", _other), do: {:error, "Logos are PNG, JPEG, WebP, GIF or SVG images."}
  defp attr(key, _value), do: {:error, "#{key} isn't part of the branding."}

  defp decode(data) when is_binary(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, bytes} when byte_size(bytes) in 1..@max_logo_bytes -> {:ok, bytes}
      {:ok, _too_big} -> {:error, "Logos can be 256 KB at most."}
      :error -> {:error, "The logo couldn't be read."}
    end
  end

  defp decode(_data), do: {:error, "The logo couldn't be read."}

  # The bytes must be what the type says.
  defp logo_matches("image/png", <<0x89, "PNG", _::binary>>), do: :ok
  defp logo_matches("image/jpeg", <<0xFF, 0xD8, 0xFF, _::binary>>), do: :ok
  defp logo_matches("image/gif", <<"GIF8", _::binary>>), do: :ok
  defp logo_matches("image/webp", <<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: :ok

  defp logo_matches("image/svg+xml", bytes) do
    start = bytes |> String.trim_leading() |> String.slice(0, 5)
    if start in ["<svg ", "<svg>", "<?xml"], do: :ok, else: logo_mismatch()
  end

  defp logo_matches(_type, _bytes), do: logo_mismatch()

  defp logo_mismatch, do: {:error, "The logo isn't the kind of image it says it is."}

  @doc false
  # GET /branding/logo. Cached for a day: its URL changes with it. Served
  # so that nothing in it runs (an SVG's scripts), and from any site that
  # links to it (emails).
  def logo(%Context{} = ctx) do
    with :ok <- License.check(),
         [%{logo: logo, logo_type: type}] when is_binary(logo) <-
           Store.all(ctx, :branding, [], limit: 1),
         {:ok, bytes} <- Base.decode64(logo) do
      headers = [
        {"content-type", type},
        {"cache-control", "public, max-age=86400"},
        {"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox"},
        {"x-content-type-options", "nosniff"},
        {"cross-origin-resource-policy", "cross-origin"}
      ]

      ctx =
        Enum.reduce(headers, ctx, fn {name, value}, ctx ->
          Context.put_resp_header(ctx, name, value)
        end)

      {:html, 200, bytes, ctx}
    else
      {:error, reason} when is_atom(reason) ->
        Log.warning("authmk branding logo refused: " <> License.explain(reason))
        {:error, Error.new(:not_found)}

      _none ->
        {:error, Error.new(:not_found)}
    end
  end
end
