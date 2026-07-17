defmodule Slink.SlashTest do
  # async: false — sets shared app env (api_base_url, test_api_sink).
  use ExUnit.Case, async: false

  alias Slink.{Context, Event}

  setup do
    {:ok, base_url, pid} = Slink.Test.FakeWebApi.start()
    Application.put_env(:slink, :api_base_url, base_url)
    Application.put_env(:slink, :test_api_sink, self())

    on_exit(fn ->
      Application.delete_env(:slink, :api_base_url)
      Application.delete_env(:slink, :test_api_sink)
      Process.exit(pid, :normal)
    end)

    {:ok, base_url: base_url}
  end

  defp slash_context(base_url) do
    event =
      Event.from_http_form(%{
        "command" => "/slink",
        "text" => "hi",
        "channel_id" => "C1",
        "user_id" => "U1",
        "response_url" => "#{base_url}/response",
        "trigger_id" => "T1"
      })

    %Context{transport: :http, bot_token: "xoxb", event: event}
  end

  test "reply/3 answers a slash command ephemerally via its response_url", %{base_url: base} do
    assert :ok = Slink.reply(slash_context(base), "on it")

    assert_receive {:api_request, "/response",
                    %{"text" => "on it", "response_type" => "ephemeral"}},
                   1_000
  end

  test "reply/3 with to: :channel answers in the channel", %{base_url: base} do
    assert :ok = Slink.reply(slash_context(base), "shipped", to: :channel)

    assert_receive {:api_request, "/response",
                    %{"text" => "shipped", "response_type" => "in_channel"}},
                   1_000
  end

  test "reply/3 carries extra opts (blocks) into the response", %{base_url: base} do
    assert :ok = Slink.reply(slash_context(base), "rich", blocks: [%{"type" => "section"}])

    assert_receive {:api_request, "/response", %{"blocks" => [%{"type" => "section"}]}}, 1_000
  end

  test "open_modal/2 opens a view with the event's trigger_id" do
    event =
      Event.from_socket_mode(%{
        "type" => "interactive",
        "payload" => %{"type" => "shortcut", "trigger_id" => "T-42"}
      })

    context = %Context{transport: :socket_mode, bot_token: "xoxb", event: event}

    assert {:ok, %{"view" => %{"id" => "V1"}}} = Slink.open_modal(context, %{"type" => "modal"})
    assert_receive {:api_request, "/views.open", %{"trigger_id" => "T-42"}}, 1_000
  end

  test "reply/3 falls back to a channel post when a slash command has no response_url" do
    event = Event.from_http_form(%{"command" => "/slink", "text" => "hi", "channel_id" => "C1"})
    context = %Context{transport: :http, bot_token: "xoxb", event: event}

    # No :rate_sender override here, so the send goes to the FakeWebApi.
    assert :ok = Slink.reply(context, "posted")

    assert_receive {:api_request, "/chat.postMessage", %{"channel" => "C1", "text" => "posted"}},
                   1_000
  end

  defp interaction(base_url, payload_extra \\ %{}) do
    payload =
      Map.merge(
        %{"type" => "block_actions", "response_url" => "#{base_url}/response"},
        payload_extra
      )

    event = Event.from_socket_mode(%{"type" => "interactive", "payload" => payload})
    %Context{transport: :socket_mode, bot_token: "xoxb", event: event}
  end

  test "reply/3 with to: :ephemeral answers an interaction via its response_url", %{
    base_url: base
  } do
    context = interaction(base, %{"channel" => %{"id" => "C1"}})
    assert :ok = Slink.reply(context, "only you", to: :ephemeral)

    assert_receive {:api_request, "/response",
                    %{
                      "text" => "only you",
                      "response_type" => "ephemeral",
                      "replace_original" => false
                    }},
                   1_000
  end

  test "reply/3 falls back to the response_url when an interaction has no channel", %{
    base_url: base
  } do
    # e.g. a button on an ephemeral message in a channel the bot isn't in.
    assert :ok = Slink.reply(interaction(base), "handled")

    assert_receive {:api_request, "/response",
                    %{"text" => "handled", "response_type" => "ephemeral"}},
                   1_000

    assert :ok = Slink.reply(interaction(base), "public", to: :channel)

    assert_receive {:api_request, "/response",
                    %{"text" => "public", "response_type" => "in_channel"}},
                   1_000
  end

  test "update_original/3 replaces the interaction's message via its response_url", %{
    base_url: base
  } do
    context = interaction(base, %{"channel" => %{"id" => "C1"}})

    assert :ok =
             Slink.update_original(context, "deploying…", blocks: [%{"type" => "section"}])

    assert_receive {:api_request, "/response",
                    %{
                      "text" => "deploying…",
                      "replace_original" => true,
                      "blocks" => [%{"type" => "section"}]
                    }},
                   1_000
  end

  test "update_original/3 returns an error when the event carries no response_url" do
    event = Event.from_socket_mode(%{"type" => "events_api", "payload" => %{"event" => %{}}})
    context = %Context{transport: :socket_mode, bot_token: "xoxb", event: event}

    assert {:error, :no_response_url} = Slink.update_original(context, "nope")
  end

  test "send_dm/4 opens the DM and posts into it", %{base_url: _base} do
    # No :rate_sender override, so the whole flow lands on the FakeWebApi:
    # conversations.open first, then the rate-limited chat.postMessage.
    context = %Context{transport: :socket_mode, bot_token: "xoxb"}

    assert :ok = Slink.send_dm(context, "U1", "psst")
    assert_receive {:api_request, "/conversations.open", %{"users" => "U1"}}, 1_000

    assert_receive {:api_request, "/chat.postMessage", %{"channel" => "D1", "text" => "psst"}},
                   1_000
  end

  test "send_dm/4 surfaces a failure to open the DM" do
    Application.put_env(:slink, :api_base_url, "http://127.0.0.1:1")
    context = %Context{transport: :socket_mode, bot_token: "xoxb"}

    assert {:error, _reason} = Slink.send_dm(context, "U1", "psst")
  end

  test "reply/3 raises for an event with no channel (e.g. a view_submission)" do
    event =
      Event.from_socket_mode(%{
        "type" => "interactive",
        "payload" => %{"type" => "view_submission", "view" => %{"callback_id" => "m"}}
      })

    context = %Context{transport: :socket_mode, bot_token: "xoxb", event: event}

    assert_raise ArgumentError, ~r/no channel/, fn -> Slink.reply(context, "nope") end
  end
end
