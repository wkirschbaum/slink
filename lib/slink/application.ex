defmodule Slink.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Handlers run here so a slow bot never blocks a transport's socket/request.
      {Task.Supervisor, name: Slink.TaskSupervisor},
      # Per-channel outbound rate limiting: a registry + one worker per channel.
      {Registry, keys: :unique, name: Slink.Rate.Registry},
      {DynamicSupervisor, name: Slink.Rate.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Slink.Supervisor)
  end
end
