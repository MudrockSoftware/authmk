defmodule Authmk.Supervisor do
  @moduledoc false
  # Started by `MyApp.Auth.child_spec/1`. Loads the config (raising on
  # invalid config), then supervises the config holder, the task supervisor
  # and the rate-limit storage.

  use Supervisor

  alias Authmk.{Background, Config}
  alias Authmk.Config.Holder

  def start_link(auth) do
    Supervisor.start_link(__MODULE__, auth, name: Module.concat(auth, Supervisor))
  end

  @impl true
  def init(auth) do
    config = Config.load(auth)

    children = [
      {Holder, config},
      {Task.Supervisor, name: Background.task_supervisor(auth)},
      {Authmk.Storage.ETS, table: Config.ets_table(auth)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
