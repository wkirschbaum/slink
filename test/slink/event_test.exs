defmodule Slink.EventTest do
  use ExUnit.Case, async: true

  alias Slink.Event

  describe "from_socket_mode/1" do
    test "unwraps an events_api envelope to the inner event" do
      envelope = %{
        "type" => "events_api",
        "envelope_id" => "abc-123",
        "payload" => %{
          "type" => "event_callback",
          "event" => %{"type" => "app_mention", "user" => "U1", "channel" => "C1"}
        }
      }

      assert %Event{
               type: :app_mention,
               kind: :event_callback,
               transport: :socket_mode,
               envelope_id: "abc-123",
               payload: %{"user" => "U1", "channel" => "C1"}
             } = Event.from_socket_mode(envelope)
    end

    test "keeps slash_commands envelopes with their payload" do
      envelope = %{
        "type" => "slash_commands",
        "envelope_id" => "e-1",
        "payload" => %{"command" => "/slink", "text" => "hi"}
      }

      assert %Event{type: :slash_commands, kind: :slash_commands, envelope_id: "e-1"} =
               Event.from_socket_mode(envelope)
    end

    test "passes through control messages like hello/disconnect" do
      assert %Event{type: "hello", kind: :other} =
               Event.from_socket_mode(%{"type" => "hello"})
    end
  end

  describe "from_http/1" do
    test "unwraps an event_callback body to the same shape as Socket Mode" do
      body = %{
        "type" => "event_callback",
        "event" => %{"type" => "message", "text" => "yo", "subtype" => nil}
      }

      assert %Event{type: :message, kind: :event_callback, transport: :http} =
               Event.from_http(body)
    end

    test "keeps url_verification as-is for the plug to answer" do
      assert %Event{type: :url_verification} =
               Event.from_http(%{"type" => "url_verification", "challenge" => "xyz"})
    end
  end

  describe "thread helpers" do
    test "surface channel/ts/thread_ts and detect a threaded event" do
      event =
        Event.from_socket_mode(%{
          "type" => "events_api",
          "payload" => %{
            "event" => %{
              "type" => "message",
              "channel" => "C1",
              "ts" => "2.0",
              "thread_ts" => "1.0"
            }
          }
        })

      assert Event.channel(event) == "C1"
      assert Event.ts(event) == "2.0"
      assert Event.thread_ts(event) == "1.0"
      assert Event.in_thread?(event)
      # Replies go into the existing thread.
      assert Event.reply_thread(event) == "1.0"
    end

    test "a top-level message is not in a thread; replying starts one on it" do
      event = %Event{payload: %{"channel" => "C1", "ts" => "2.0"}, raw: %{}, transport: :http}

      refute Event.in_thread?(event)
      assert Event.reply_thread(event) == "2.0"
    end
  end

  describe "thread helpers for block_actions interactions" do
    defp interaction(message) do
      Event.from_socket_mode(%{
        "type" => "interactive",
        "payload" => %{
          "type" => "block_actions",
          "channel" => %{"id" => "C1", "name" => "general"},
          "message" => message
        }
      })
    end

    test "read the channel and thread from the clicked message, not payload['channel']" do
      event = interaction(%{"ts" => "2.0", "thread_ts" => "1.0"})

      # payload["channel"] is a map for block_actions — the accessor must dig in.
      assert Event.channel(event) == "C1"
      assert Event.ts(event) == "2.0"
      assert Event.thread_ts(event) == "1.0"
      assert Event.in_thread?(event)
      assert Event.reply_thread(event) == "1.0"
    end

    test "a click on a top-level message is not in a thread; a reply starts one" do
      event = interaction(%{"ts" => "2.0"})

      refute Event.in_thread?(event)
      assert Event.reply_thread(event) == "2.0"
    end

    test "fall back to the container when the message isn't present" do
      event =
        Event.from_socket_mode(%{
          "type" => "interactive",
          "payload" => %{
            "type" => "block_actions",
            "container" => %{"channel_id" => "C9", "message_ts" => "5.0", "thread_ts" => "4.0"}
          }
        })

      assert Event.channel(event) == "C9"
      assert Event.ts(event) == "5.0"
      assert Event.thread_ts(event) == "4.0"
    end
  end

  describe "author and mention helpers" do
    defp msg(payload), do: %Event{payload: payload, raw: %{}, transport: :socket_mode}

    test "from_bot?/1 is true only when a bot_id is present" do
      assert Event.from_bot?(msg(%{"bot_id" => "B1", "text" => "hi"}))
      refute Event.from_bot?(msg(%{"user" => "U1", "text" => "hi"}))
    end

    test "text/1 and user/1 surface the payload, with a safe default for text" do
      assert Event.text(msg(%{"text" => "hello"})) == "hello"
      assert Event.text(msg(%{})) == ""
      assert Event.user(msg(%{"user" => "U1"})) == "U1"
      assert Event.user(msg(%{})) == nil
    end

    test "mention?/1 is true for app_mention events" do
      assert Event.mention?(%Event{
               type: :app_mention,
               payload: %{},
               raw: %{},
               transport: :socket_mode
             })

      refute Event.mention?(%Event{
               type: :message,
               payload: %{},
               raw: %{},
               transport: :socket_mode
             })
    end

    test "mentions/1 lists mentioned user ids in order; mentions?/2 checks one" do
      event = msg(%{"text" => "<@U0BOT> ping <@U123> and <@U456>"})
      assert Event.mentions(event) == ["U0BOT", "U123", "U456"]
      assert Event.mentions?(event, "U123")
      refute Event.mentions?(event, "U999")
      assert Event.mentions(msg(%{"text" => "no mentions here"})) == []
    end

    test "mentions/1 also handles the labeled <@ID|name> form" do
      event = msg(%{"text" => "<@U0123|alice> and <@U456>"})
      assert Event.mentions(event) == ["U0123", "U456"]
      assert Event.mentions?(event, "U0123")
    end

    test "command/1 strips a leading mention and trims" do
      assert Event.command(msg(%{"text" => "<@U0BOT> deploy now"})) == "deploy now"
      assert Event.command(msg(%{"text" => "   <@U0BOT>   hi  "})) == "hi"
      # No leading mention: returned trimmed, unchanged otherwise.
      assert Event.command(msg(%{"text" => "just text"})) == "just text"
    end
  end
end
