defmodule Authmk.Plugins.OAuthProvider.Config do
  @moduledoc false
  # The plugin's options, for its handler modules. They find the plugin
  # through the endpoint (or, for server-side calls, the context), so they
  # don't depend on the plugin module, which depends on them.

  alias Authmk.Context

  def opts(%Context{private: %{oauth_provider_plugin: plugin}} = ctx),
    do: Context.plugin_opts(ctx, plugin)

  def opts(%Context{endpoint: %{plugin: plugin}} = ctx) when not is_nil(plugin),
    do: Context.plugin_opts(ctx, plugin)

  @doc "The issuer identifier: the `issuer` option, or the base URL and path."
  def issuer(%Context{config: config} = ctx),
    do: opts(ctx)[:issuer] || base_url(ctx) <> config.base_path

  # Server-side calls (a revocation from your code) have no request.
  defp base_url(%Context{base_url: nil, config: config}) do
    {:ok, base_url} = Authmk.BaseURL.resolve(config, nil)
    base_url
  end

  defp base_url(%Context{base_url: base_url}), do: base_url
end
