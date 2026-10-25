defmodule Authmk.Supervisor do
  @moduledoc false
  # Started by `MyApp.Auth.child_spec/1`. Loads the config (raising on
  # invalid config), then supervises the config holder, the task supervisor
  # and the rate-limit storage.

  use Supervisor

  alias Authmk.{Background, Config, SchemaCheck}
  alias Authmk.Config.Holder
  alias Authmk.Storage.ETS

  def start_link(auth) do
    Supervisor.start_link(__MODULE__, auth, name: Module.concat(auth, Supervisor))
  end

  @impl true
  def init(auth) do
    config = Config.load(auth)

    if config.advanced[:validate_schema] do
      with {:error, message} <- SchemaCheck.run(config) do
        raise ArgumentError,
              "#{inspect(auth)}: the database doesn't match the schema.\n" <> message
      end
    end

    children = [
      {Holder, config},
      {Task.Supervisor, name: Background.task_supervisor(auth)},
      {ETS, table: ETS.table(auth)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
