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
               type: "app_mention",
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

      assert %Event{type: "slash_commands", kind: :slash_commands, envelope_id: "e-1"} =
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

      assert %Event{type: "message", kind: :event_callback, transport: :http} =
               Event.from_http(body)
    end

    test "keeps url_verification as-is for the plug to answer" do
      assert %Event{type: "url_verification"} =
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
end
