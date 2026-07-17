defmodule Slink.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Handlers run here so a slow bot never blocks a transport's socket/request.
      # `config :slink, :max_handler_tasks, N` caps concurrent handlers (default
      # :infinity) — an opt-in backpressure valve against event floods; past the
      # cap the dispatcher sheds events with an error log. Read at boot.
      {Task.Supervisor,
       name: Slink.TaskSupervisor,
       max_children: Application.get_env(:slink, :max_handler_tasks, :infinity)},
      # Per-channel outbound rate limiting: a registry + one worker per channel.
      {Registry, keys: :unique, name: Slink.Rate.Registry},
      {DynamicSupervisor, name: Slink.Rate.Supervisor, strategy: :one_for_one},
      # Remembers recently-seen event ids so retried deliveries dispatch once.
      Slink.Dedup,
      # Caches auth.test per token so contexts can carry the bot's own user id.
      Slink.Identity
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Slink.Supervisor)
  end
end
