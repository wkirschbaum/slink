defmodule Slink.ExampleBot do
  @moduledoc """
  A tiny example bot. Replies to `app_mention` events and logs everything else.

  Run it in IEx (Socket Mode):

      iex -S mix
      iex> {:ok, _} = Slink.SocketMode.start_link(
      ...>   module: Slink.ExampleBot,
      ...>   app_token: System.fetch_env!("SLACK_APP_TOKEN"),
      ...>   bot_token: System.fetch_env!("SLACK_BOT_TOKEN"))
  """

  use Slink
  require Logger

  alias Slink.Event

  @impl true
  def handle_event(%Event{type: "app_mention"} = event, ctx) do
    user = event.payload["user"]

    # reply/3 threads automatically — in a thread it stays in the thread,
    # otherwise it starts one on the message that mentioned us.
    if Event.in_thread?(event) do
      reply(ctx, event, "hi <@#{user}> 👋 (replying in this thread)")
    else
      reply(ctx, event, "hi <@#{user}> 👋")
    end

    :ok
  end

  def handle_event(%Event{type: type}, _ctx) do
    Logger.debug("ExampleBot: unhandled event #{inspect(type)}")
    :ok
  end
end
