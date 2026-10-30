defmodule Authmk.Background do
  @moduledoc """
  Runs side work, such as sending emails, without delaying the response.

    * `background: :task` (the default): a supervised task.
    * `background: :inline`: in the calling process, as tests use.
    * `background: {:oban, name: Oban, queue: :default}`: an Oban job, so
      the work survives a restart and is retried (`max_attempts: 5` by
      default). Add `{:oban, "~> 2.19"}` to your deps.

  Work is data, not a closure, so it can wait in a queue across deploys: a
  callback of the auth module (`send_reset_password`...), a plugin
  option's function (`send_otp`...), or an internal function. Oban jobs
  hold it encrypted with the secret (it carries links and codes), and the
  callback gets a context built from the config and the request's base URL:
  without the request itself (`ctx.conn` is `nil`).
  """

  alias Authmk.{Context, Crypto, Deliveries}

  @purpose "background-job"

  @typedoc false
  @type job ::
          {:callback, atom(), map()}
          | {:plugin, module(), atom(), map()}
          | {:call, module(), atom(), list()}

  @doc "Runs the auth module's `callback` with `data` (and the context)."
  @spec callback(Context.t(), atom(), map()) :: :ok
  def callback(ctx, callback, data), do: run(ctx, {:callback, callback, data})

  @doc "Runs the function in `plugin`'s option `key` with `data` (and the context)."
  @spec plugin_callback(Context.t(), module(), atom(), map()) :: :ok
  def plugin_callback(ctx, plugin, key, data), do: run(ctx, {:plugin, plugin, key, data})

  @doc "Runs `module.function(ctx, args...)`."
  @spec call(Context.t(), module(), atom(), list()) :: :ok
  def call(ctx, module, function, args), do: run(ctx, {:call, module, function, args})

  defp run(%Context{config: config} = ctx, job) do
    case config.background do
      :inline ->
        perform(ctx, job)
        :ok

      :task ->
        supervisor = task_supervisor(config.auth)
        {:ok, _pid} = Task.Supervisor.start_child(supervisor, fn -> perform(ctx, job) end)
        :ok

      {:oban, opts} ->
        enqueue(ctx, job, opts)
    end
  end

  @doc false
  # Emails and text messages are remembered for the dashboard's health
  # checks (Authmk.Deliveries). A crash still crashes, for Oban to retry.
  @spec perform(Context.t(), job()) :: term()
  def perform(ctx, job) do
    result = execute(ctx, job)
    :ok = Deliveries.record(ctx, job, result)
    result
  rescue
    exception ->
      :ok = Deliveries.record(ctx, job, exception)
      reraise exception, __STACKTRACE__
  end

  defp execute(%Context{config: config} = ctx, {:callback, callback, data}),
    do: apply(config.auth, callback, [data, ctx])

  defp execute(ctx, {:plugin, plugin, key, data}),
    do: Context.plugin_opts(ctx, plugin)[key].(data, ctx)

  defp execute(ctx, {:call, module, function, args}), do: apply(module, function, [ctx | args])

  defp enqueue(%Context{config: config} = ctx, job, opts) do
    args = %{
      "auth" => Atom.to_string(config.auth),
      "base_url" => ctx.base_url,
      "job" => Crypto.encrypt(config, @purpose, :erlang.term_to_binary(job))
    }

    worker = Module.concat(Authmk.Background, ObanWorker)

    changeset =
      worker.new(args,
        queue: Keyword.get(opts, :queue, :default),
        max_attempts: Keyword.get(opts, :max_attempts, 5)
      )

    # Oban is optional: called by name, so authmk compiles without it.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    {:ok, _job} = apply(Oban, :insert, [Keyword.get(opts, :name, Oban), changeset])
    :ok
  end

  @doc false
  # The Oban worker's half: the job back from its encrypted args.
  @spec decode(map()) :: {:ok, Context.t(), job()} | :error
  def decode(%{"auth" => auth, "base_url" => base_url, "job" => encrypted}) do
    auth = String.to_existing_atom(auth)
    config = auth.config()

    case Crypto.decrypt(config, @purpose, encrypted) do
      {:ok, binary} ->
        ctx = %{Context.new(config) | base_url: base_url}
        {:ok, ctx, :erlang.binary_to_term(binary, [:safe])}

      :error ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Name of the auth module's task supervisor."
  @spec task_supervisor(module()) :: atom()
  def task_supervisor(auth), do: Module.concat(auth, TaskSupervisor)
end
