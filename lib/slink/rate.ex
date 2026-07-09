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
  """

  alias Slink.Rate.Channel

  @doc "Queue a `chat.postMessage` for `channel`, rate-limited per channel."
  def post_message(bot_token, channel, text, opts \\ %{}) do
    params = Map.merge(%{channel: channel, text: text}, opts)
    enqueue(bot_token, channel, "chat.postMessage", params)
  end

  @doc "Queue any Web API `method` targeting `channel`, rate-limited per channel."
  def enqueue(bot_token, channel, method, params) do
    channel
    |> worker()
    |> GenServer.cast({:enqueue, {bot_token, method, params}})
  end

  defp worker(channel) do
    case Registry.lookup(Slink.Rate.Registry, channel) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(Slink.Rate.Supervisor, {Channel, channel}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end
