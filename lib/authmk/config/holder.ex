defmodule Authmk.Config.Holder do
  @moduledoc false
  # Stores the config in :persistent_term while the auth module runs, and
  # erases it when the auth module stops.

  use GenServer

  alias Authmk.Config

  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    Config.put(config)
    {:ok, config.auth}
  end

  @impl true
  def terminate(_reason, auth) do
    Config.erase(auth)
  end
end
