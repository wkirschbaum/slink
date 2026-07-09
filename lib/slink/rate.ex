defmodule Slink.Rate do
  @moduledoc """
  Per-channel outbound rate limiting for Slack Web API calls.

  Slack limits `chat.postMessage` to roughly **one message per second per
  channel**; bursts beyond that get `429`s and dropped messages. This module
  fronts outbound calls with one lightweight `GenServer` per channel (see
  `Slink.Rate.Channel`), each draining a FIFO queue no faster than the
  configured interval. Different channels drain concurrently.

  Calls are fire-and-forget: failures are logged, not returned. Use
  `Slink.API` directly if you need the response.

  ## Configuration

    * `config :slink, :rate_interval_ms, 1_000` — minimum gap between sends on a
      single channel (default 1000ms).
    * `config :slink, :rate_max_queue, 1_000` — per-channel queue cap; beyond it
      the oldest queued messages are dropped (default 1000).
    * `config :slink, :rate_idle_stop_ms, 600_000` — a channel worker with
      nothing to do for this long stops itself (default 10 minutes), so posting
      to many channels doesn't accumulate idle workers.
  """

  require Logger

  alias Slink.Rate.Channel

  @doc "Queue a `chat.postMessage` for `channel`, rate-limited per channel."
  def post_message(bot_token, channel, text, opts \\ %{}) do
    params = Map.merge(%{channel: channel, text: text}, opts)
    enqueue(bot_token, channel, "chat.postMessage", params)
  end

  @doc "Queue any Web API `method` targeting `channel`, rate-limited per channel."
  def enqueue(bot_token, channel, method, params) do
    case worker(channel) do
      {:ok, pid} -> GenServer.cast(pid, {:enqueue, {bot_token, method, params}})
      :error -> :ok
    end
  end

  defp worker(channel) do
    case Registry.lookup(Slink.Rate.Registry, channel) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        start_worker(channel)
    end
  end

  # Start a channel worker, tolerating the start/lookup race. If it can't be
  # started for any other reason, drop the send rather than crash the caller —
  # a failed rate-limit worker must never take down a handler or transport.
  defp start_worker(channel) do
    case DynamicSupervisor.start_child(Slink.Rate.Supervisor, {Channel, channel}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning(
          "Slink.Rate: could not start worker for #{inspect(channel)}: #{inspect(reason)}"
        )

        :error
    end
  end
end
