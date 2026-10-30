defmodule Authmk.SMS.Test do
  @moduledoc """
  An `Authmk.SMS` sender for tests: messages go to the test process as
  `{:sms, to, body}` (the process making the request, or the one that
  started the background task sending them).

      assert_receive {:sms, "+15551234567", body}
  """

  @behaviour Authmk.SMS

  @impl true
  def deliver(to, body, _opts) do
    pid =
      case Process.get(:"$callers") do
        [_ | _] = callers -> List.last(callers)
        _none -> self()
      end

    send(pid, {:sms, to, body})
    :ok
  end
end
