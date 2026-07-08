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
  def handle_event(%Event{type: "app_mention"} = event, _context) do
    # Return the reply and slink sends it. `to: :auto` (the default) keeps it in
    # the thread when the mention was in one, otherwise answers inline.
    {:reply, "hi <@#{Event.user(event)}> 👋"}
  end

  def handle_event(%Event{type: type}, _context) do
    Logger.debug("ExampleBot: unhandled event #{inspect(type)}")
    :ok
  end
end
