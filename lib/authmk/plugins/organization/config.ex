defmodule Authmk.Plugins.Organization.Config do
  @moduledoc false
  # The plugin's options, for its handler modules. They find the plugin
  # through the endpoint (or, for server-side calls, the context), so they
  # don't depend on the plugin module, which depends on them.

  alias Authmk.Context

  def opts(ctx), do: Context.plugin_opts(ctx, plugin(ctx))

  def plugin(%Context{private: %{organization_plugin: plugin}}), do: plugin
  def plugin(%Context{endpoint: %{plugin: plugin}}), do: plugin
end
