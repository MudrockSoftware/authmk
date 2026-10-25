defmodule PlugApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [PlugApp.Repo] ++
        if Application.get_env(:plug_app, :server, true) do
          [{Bandit, plug: PlugApp.Router, port: Application.fetch_env!(:plug_app, :port)}]
        else
          []
        end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PlugApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
