defmodule Authmk.Background do
  @moduledoc """
  Runs side work, such as sending emails, without delaying the response.

  With `background: :task` (the default) work runs in a supervised task. With
  `background: :inline` it runs in the calling process, which tests use.
  """

  alias Authmk.Context

  @doc "Runs `fun` in the background, or inline."
  @spec run(Context.t(), (-> term())) :: :ok
  def run(%Context{config: config}, fun) do
    case config.background do
      :inline ->
        fun.()
        :ok

      :task ->
        {:ok, _pid} = Task.Supervisor.start_child(task_supervisor(config.auth), fun)
        :ok
    end
  end

  @doc "Name of the auth module's task supervisor."
  @spec task_supervisor(module()) :: atom()
  def task_supervisor(auth), do: Module.concat(auth, TaskSupervisor)
end
