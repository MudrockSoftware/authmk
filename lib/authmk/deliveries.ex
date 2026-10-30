defmodule Authmk.Deliveries do
  @moduledoc false
  # What happened to the last emails and text messages authmk handed to
  # the app's senders (callbacks like `send_reset_password`, plugin options
  # like PhoneNumber's `send_otp`), on this node: when one last went out,
  # when one last failed and why. For the dashboard's health checks.
  #
  # Kept in the auth module's ETS table, so it's per node and starts empty
  # after a restart. Only names, times and the kind of failure: never the
  # message, the address or the code.

  alias Authmk.Context
  alias Authmk.Storage.ETS

  @ttl 30 * 86_400
  @key "deliveries"

  @type delivery :: %{
          name: String.t(),
          channel: :email | :sms,
          last_sent_at: DateTime.t() | nil,
          last_failed_at: DateTime.t() | nil,
          failure: String.t() | nil,
          not_implemented: boolean()
        }

  @doc "Records how a background job went, when it's a delivery."
  @spec record(Context.t(), tuple(), term()) :: :ok
  def record(%Context{config: config}, job, result) do
    case delivery(job) do
      nil -> :ok
      {name, channel} -> update(config.auth, name, channel, outcome(result))
    end
  end

  @doc "Records that the auth module doesn't implement an email callback."
  @spec not_implemented(module(), atom()) :: :ok
  def not_implemented(auth, callback),
    do: update(auth, Atom.to_string(callback), :email, :not_implemented)

  @doc "Every delivery seen on this node, by name."
  @spec list(module()) :: [delivery()]
  def list(auth) do
    auth |> read() |> Map.values() |> Enum.sort_by(& &1.name)
  end

  defp delivery({:callback, callback, _data}), do: sender(Atom.to_string(callback), :email)

  # By name: plugins call this module (through Background), so it doesn't
  # call them.
  defp delivery({:plugin, plugin, key, _data}) do
    channel = if inspect(plugin) == "Authmk.Plugins.PhoneNumber", do: :sms, else: :email
    sender(inspect(plugin) <> " " <> Atom.to_string(key), channel)
  end

  defp delivery(_job), do: nil

  defp sender(name, channel) do
    if String.contains?(name, "send_"), do: {name, channel}
  end

  defp outcome({:error, reason}), do: {:failed, failure(reason)}
  defp outcome(%{__exception__: true} = exception), do: {:failed, inspect(exception.__struct__)}
  defp outcome(_sent), do: :sent

  # The kind of failure, never its details: they may hold an address.
  defp failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure(%{__struct__: struct}), do: inspect(struct)
  defp failure(_reason), do: "error"

  defp update(auth, name, channel, outcome) do
    now = DateTime.utc_now()

    entry =
      Map.get(read(auth), name, %{
        name: name,
        channel: channel,
        last_sent_at: nil,
        last_failed_at: nil,
        failure: nil,
        not_implemented: false
      })

    entry =
      case outcome do
        :sent -> %{entry | last_sent_at: now}
        {:failed, failure} -> %{entry | last_failed_at: now, failure: failure}
        :not_implemented -> %{entry | last_failed_at: now, not_implemented: true}
      end

    ETS.put([table: ETS.table(auth)], @key, Map.put(read(auth), name, entry), @ttl)
  rescue
    # No table (the auth module isn't started): nothing to remember.
    ArgumentError -> :ok
  end

  defp read(auth) do
    ETS.get([table: ETS.table(auth)], @key) || %{}
  rescue
    ArgumentError -> %{}
  end
end
