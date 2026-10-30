defmodule Authmk.Testing.Inbox do
  @moduledoc """
  Catches the codes and links authmk sends (emails, SMS), for tests.

  Point the send callbacks at `deliver/2` in your test config, or call it
  from your own:

      # lib/my_app/auth.ex
      {Authmk.Plugins.EmailOTP, send_otp: &MyApp.Auth.send_email_code/2}

      def send_email_code(message, ctx) do
        if Application.get_env(:my_app, :capture_auth_messages),
          do: Authmk.Testing.Inbox.deliver(message, ctx),
          else: MyApp.Mailer.deliver_code(message)
      end

  Then, in the test that triggered it:

      %{otp: code} = Authmk.Testing.Inbox.receive!(to: "ada@example.com")

  Messages are the maps authmk gives the callbacks (`:otp`, `:url`,
  `:token`, `:user`, `:email`, `:phone_number`...). They go to the test
  process: the one making the request, or the one that started the
  background task sending them.
  """

  @doc "A send callback: hands `message` to the test process."
  @spec deliver(map(), term()) :: :ok
  def deliver(message, _ctx) do
    send(test_process(), {__MODULE__, message})
    :ok
  end

  @doc """
  Waits for the next message (for `:to`, an email or phone number, when
  given) and returns it. Raises after `:timeout` ms (default 100).
  """
  @spec receive!(keyword()) :: map()
  def receive!(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 100)
    deadline = System.monotonic_time(:millisecond) + timeout

    case await(opts[:to], deadline, []) do
      {:ok, message} ->
        message

      :timeout ->
        raise "no authmk message#{if opts[:to], do: " for #{opts[:to]}"} within #{timeout}ms"
    end
  end

  # Messages for others go back in the mailbox.
  defp await(to, deadline, skipped) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {__MODULE__, message} ->
        if is_nil(to) or recipient(message) == to do
          put_back(skipped)
          {:ok, message}
        else
          await(to, deadline, [message | skipped])
        end
    after
      wait ->
        put_back(skipped)
        :timeout
    end
  end

  defp put_back(skipped),
    do: skipped |> Enum.reverse() |> Enum.each(&send(self(), {__MODULE__, &1}))

  @doc "Whether no message is waiting."
  @spec empty?() :: boolean()
  def empty? do
    receive do
      {__MODULE__, _message} = waiting ->
        send(self(), waiting)
        false
    after
      0 -> true
    end
  end

  defp recipient(%{email: email}) when is_binary(email), do: email
  defp recipient(%{phone_number: number}) when is_binary(number), do: number
  defp recipient(%{user: %{email: email}}), do: email
  defp recipient(_message), do: nil

  defp test_process do
    case Process.get(:"$callers") do
      [_ | _] = callers -> List.last(callers)
      _none -> self()
    end
  end
end
