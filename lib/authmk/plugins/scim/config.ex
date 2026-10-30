defmodule Authmk.Plugins.SCIM.Config do
  @moduledoc false
  # The plugin's options, for its handler modules, found through the
  # endpoint so they don't depend on the plugin module.

  alias Authmk.Context

  def opts(%Context{private: %{scim_plugin: plugin}} = ctx), do: Context.plugin_opts(ctx, plugin)

  def opts(%Context{endpoint: %{plugin: plugin}} = ctx) when not is_nil(plugin),
    do: Context.plugin_opts(ctx, plugin)
end
