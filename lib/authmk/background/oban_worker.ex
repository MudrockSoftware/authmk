if Code.ensure_loaded?(Oban.Worker) do
  defmodule Authmk.Background.ObanWorker do
    @moduledoc """
    Runs authmk's background work as Oban jobs, with
    `background: {:oban, name: Oban, queue: :default}`. See
    `Authmk.Background`.
    """

    use Oban.Worker

    alias Authmk.Background

    @impl Oban.Worker
    def perform(%Oban.Job{args: args}) do
      case Background.decode(args) do
        {:ok, ctx, job} ->
          Background.perform(ctx, job)
          :ok

        # Encrypted with a secret that's gone: retrying won't help.
        :error ->
          {:cancel, :undecryptable}
      end
    end
  end
end
