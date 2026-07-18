defmodule Slink.Test.PlaygroundTestBot do
  @moduledoc false
  # The bot the playground tests drive: one handler per surface under test.
  use Slink

  alias Slink.{BlockKit, Event}

  @impl true
  def handle_event(%Event{type: :app_mention} = event, _context) do
    {:reply, "hi <@#{Event.user(event)}>!"}
  end

  def handle_event(%Event{type: :slash_commands} = event, context) do
    case Event.command_name(event) do
      "/modal" ->
        {:ok, _response} = open_modal(context, modal())
        :ok

      _other ->
        {:reply, "you said: #{Event.command(event)}"}
    end
  end

  def handle_event(%Event{type: :block_actions} = event, context) do
    update_original(context, "clicked #{Event.action_value(event)}")
  end

  def handle_event(%Event{type: :view_submission} = event, _context) do
    case Event.view_values(event) do
      %{"note" => %{"note" => %{"value" => value}}} when value not in [nil, ""] ->
        :ok

      _empty ->
        {:ack, %{response_action: "errors", errors: %{"note" => "say something"}}}
    end
  end

  def handle_event(%Event{type: :app_home_opened} = event, context) do
    view = %{type: "home", blocks: [BlockKit.section("welcome home")]}
    {:ok, _response} = Slink.API.publish_view(context.bot_token, Event.user(event), view)
    :ok
  end

  def handle_event(_event, _context), do: :ok

  defp modal do
    BlockKit.modal(
      "Test modal",
      [BlockKit.input("Note", BlockKit.plain_text_input(action_id: "note"), block_id: "note")],
      submit: "Save",
      callback_id: "test-modal"
    )
  end
end
