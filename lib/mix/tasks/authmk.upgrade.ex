if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Authmk.Upgrade do
    @shortdoc "Upgrades your app between authmk versions"

    @moduledoc """
    Brings your app along when authmk changes:

        mix igniter.upgrade authmk

    Igniter updates the dependency, then runs this task with the old and new
    versions (or run it yourself: `mix authmk.upgrade 0.1.0 0.2.0`). It:

      * applies the code changes each version in between needs (renamed
        options, moved modules), in order, showing you the diff first;
      * generates the migration for whatever changed in authmk's schema;
      * lists what to check by hand.

    Review the diff and the migration before running it.
    """

    use Igniter.Mix.Task

    # Code changes per version, oldest first: "version" => [fn igniter, opts -> igniter end].
    # A version that only changes the schema needs none: the migration covers it.
    @upgrades %{}

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{group: :authmk, positional: [:from, :to]}
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      %{from: from, to: to} = igniter.args.positional

      case {Version.parse(from), Version.parse(to)} do
        {{:ok, old}, {:ok, new}} ->
          if Version.compare(old, new) == :lt,
            do: upgrade(igniter, from, to),
            else: Igniter.add_notice(igniter, "authmk #{from} to #{to}: nothing to upgrade.")

        _invalid ->
          Igniter.add_issue(igniter, "Give versions like `mix authmk.upgrade 0.1.0 0.2.0`.")
      end
    end

    defp upgrade(igniter, from, to) do
      igniter
      |> Igniter.Upgrades.run(from, to, @upgrades, [])
      |> Igniter.add_task("authmk.gen.migration")
      |> Igniter.add_notice("""
      authmk upgraded from #{from} to #{to}.
      Review the new migration in priv/repo/migrations, run `mix ecto.migrate`,
      and run `mix authmk.info` to check the setup.
      """)
    end
  end
end
