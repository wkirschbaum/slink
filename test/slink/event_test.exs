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

    test "app_mention?/1 is true for app_mention events" do
      assert Event.app_mention?(%Event{
               type: :app_mention,
               payload: %{},
               raw: %{},
               transport: :socket_mode
             })

      refute Event.app_mention?(%Event{
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

    test "command/1 unwraps a linkified email (mailto) to the bare address" do
      email = "wilhelm.kirschbaum@highspeed.training"
      assert Event.command(msg(%{"text" => "<@U0BOT> <mailto:#{email}|#{email}>"})) == email
      assert Event.command(msg(%{"text" => "<mailto:#{email}>"})) == email
    end

    test "command/1 unwraps other Slack markup to plain text" do
      # user/channel → their label; a labelless user mention drops out; url stays
      assert Event.command(msg(%{"text" => "ping <@U9|alice> in <#C1|general>"})) ==
               "ping alice in general"

      assert Event.command(msg(%{"text" => "see <https://x.dev/docs|the docs>"})) ==
               "see https://x.dev/docs"

      assert Event.command(msg(%{"text" => "<@U0BOT> hi <@U9>"})) == "hi"
    end
  end

  describe "reaction events" do
    test "channel/1 and ts/1 read the reacted-to item" do
      event =
        Event.from_socket_mode(%{
          "type" => "events_api",
          "payload" => %{
            "event" => %{
              "type" => "reaction_added",
              "user" => "U1",
              "reaction" => "thumbsup",
              "item" => %{"type" => "message", "channel" => "C9", "ts" => "3.0"}
            }
          }
        })

      assert event.type == :reaction_added
      assert Event.channel(event) == "C9"
      assert Event.ts(event) == "3.0"
      # A reply threads on the reacted message (no thread_ts on the item).
      assert Event.reply_thread(event) == "3.0"
    end
  end

  describe "interactions surface their inner type" do
    test "from_socket_mode routes block_actions/view_submission on the inner type" do
      assert %Event{type: :block_actions, kind: :interactive} =
               Event.from_socket_mode(%{
                 "type" => "interactive",
                 "payload" => %{"type" => "block_actions"}
               })

      assert %Event{type: :view_submission, kind: :interactive} =
               Event.from_socket_mode(%{
                 "type" => "interactive",
                 "payload" => %{"type" => "view_submission"}
               })
    end
  end

  describe "from_http_form/1" do
    test "treats a `payload` field as a JSON interaction, on the inner type" do
      form = %{"payload" => JSON.encode!(%{"type" => "block_actions", "trigger_id" => "T1"})}

      assert %Event{type: :block_actions, kind: :interactive, transport: :http} =
               event =
               Event.from_http_form(form)

      assert Event.trigger_id(event) == "T1"
    end

    test "treats other forms as a slash command whose fields are the payload" do
      form = %{
        "command" => "/deploy",
        "text" => "web prod",
        "user_id" => "U1",
        "channel_id" => "C1",
        "response_url" => "https://hooks.slack/r/1",
        "trigger_id" => "T1"
      }

      event = Event.from_http_form(form)

      assert %Event{type: :slash_commands, kind: :slash_commands, transport: :http} = event
      assert Event.command_name(event) == "/deploy"
      assert Event.text(event) == "web prod"
      assert Event.user(event) == "U1"
      assert Event.channel(event) == "C1"
      assert Event.response_url(event) == "https://hooks.slack/r/1"
    end

    test "tolerates an undecodable payload field" do
      assert %Event{kind: :interactive, payload: %{}} =
               Event.from_http_form(%{"payload" => "not json"})
    end
  end

  describe "interaction accessors" do
    defp block_actions do
      Event.from_socket_mode(%{
        "type" => "interactive",
        "payload" => %{
          "type" => "block_actions",
          "user" => %{"id" => "U1", "username" => "alice"},
          "trigger_id" => "T1",
          "response_url" => "https://hooks.slack/r/1",
          "actions" => [
            %{"action_id" => "approve", "value" => "yes"},
            %{"action_id" => "pick", "selected_option" => %{"value" => "b"}}
          ]
        }
      })
    end

    test "user/1 digs the nested id out of an interaction" do
      assert Event.user(block_actions()) == "U1"
    end

    test "actions/action_id/action_value read the first action" do
      event = block_actions()
      assert length(Event.actions(event)) == 2
      assert Event.action_id(event) == "approve"
      assert Event.action_value(event) == "yes"
    end

    test "action_value falls back to a select menu's selected_option" do
      event =
        Event.from_socket_mode(%{
          "type" => "interactive",
          "payload" => %{
            "type" => "block_actions",
            "actions" => [%{"action_id" => "pick", "selected_option" => %{"value" => "b"}}]
          }
        })

      assert Event.action_value(event) == "b"
    end

    test "view/view_values/callback_id read a view_submission" do
      event =
        Event.from_socket_mode(%{
          "type" => "interactive",
          "payload" => %{
            "type" => "view_submission",
            "view" => %{
              "callback_id" => "my_modal",
              "state" => %{"values" => %{"block" => %{"input" => %{"value" => "x"}}}}
            }
          }
        })

      assert Event.callback_id(event) == "my_modal"
      assert Event.view(event)["callback_id"] == "my_modal"
      assert Event.view_values(event) == %{"block" => %{"input" => %{"value" => "x"}}}
    end
  end

  describe "dedup and retry helpers" do
    test "event_id/1 reads the id from either transport's shape" do
      socket =
        Event.from_socket_mode(%{
          "type" => "events_api",
          "payload" => %{"event_id" => "Ev1", "event" => %{"type" => "message"}}
        })

      http = Event.from_http(%{"type" => "event_callback", "event_id" => "Ev2", "event" => %{}})

      assert Event.event_id(socket) == "Ev1"
      assert Event.event_id(http) == "Ev2"
    end

    test "retry_attempt/retry? reflect the delivery's retry count" do
      first = Event.from_http(%{"type" => "event_callback", "event" => %{}})
      retried = Event.from_http(%{"type" => "event_callback", "event" => %{}, "retry_num" => 2})

      refute Event.retry?(first)
      assert Event.retry_attempt(first) == 0
      assert Event.retry?(retried)
      assert Event.retry_attempt(retried) == 2
    end
  end

  describe "totality: malformed payloads never raise" do
    # Slack always sends well-formed objects, but a malformed or hostile frame
    # can put a string/list/null where a map is expected. None of the parsing or
    # accessors may raise — much of this runs in a transport process where a raise
    # drops the connection.

    test "from_socket_mode tolerates a non-map payload for every envelope kind" do
      for type <- ["events_api", "slash_commands", "interactive"],
          bad <- ["a string", 123, nil, ["a", "list"]] do
        env = %{"type" => type, "envelope_id" => "e", "payload" => bad}
        event = Event.from_socket_mode(env)
        assert is_map(event.payload)
        # And the accessors on the resulting event stay safe.
        assert Event.channel(event) == nil or is_binary(Event.channel(event))
        assert Event.text(event) == ""
        assert Event.event_id(event) == nil
        assert Event.actions(event) == []
      end
    end

    test "from_socket_mode tolerates an events_api event that isn't a map" do
      env = %{
        "type" => "events_api",
        "envelope_id" => "e",
        "payload" => %{"type" => "event_callback", "event" => "not a map"}
      }

      event = Event.from_socket_mode(env)
      assert event.payload == %{}
      assert Event.channel(event) == nil
    end

    test "from_http and from_http_form tolerate non-map bodies" do
      for bad <- ["str", 123, ["list"], nil] do
        assert %Event{payload: %{}} = Event.from_http(bad)
        assert %Event{payload: %{}} = Event.from_http_form(bad)
      end
    end

    test "nested accessors return nil when Slack's nested maps are the wrong shape" do
      # An interactive payload where `channel`, `message`, `user`, `view` are all
      # strings instead of the maps Slack normally sends.
      env = %{
        "type" => "interactive",
        "envelope_id" => "e",
        "payload" => %{
          "type" => "block_actions",
          "channel" => "should-be-a-map",
          "message" => "should-be-a-map",
          "user" => "should-be-a-map",
          "view" => "should-be-a-map",
          "actions" => "should-be-a-list"
        }
      }

      event = Event.from_socket_mode(env)

      assert Event.channel(event) == nil
      assert Event.ts(event) == nil
      assert Event.thread_ts(event) == nil
      assert Event.user(event) == nil
      assert Event.callback_id(event) == nil
      assert Event.view_values(event) == %{}
      assert Event.actions(event) == []
      assert Event.action_id(event) == nil
      assert Event.action_value(event) == nil
    end

    test "text/mentions/command tolerate a non-string text field" do
      event =
        Event.from_socket_mode(%{
          "type" => "events_api",
          "payload" => %{"event" => %{"text" => 123}}
        })

      assert Event.text(event) == ""
      assert Event.mentions(event) == []
      assert Event.command(event) == ""
    end

    test "action_value tolerates non-map action entries" do
      env = %{
        "type" => "interactive",
        "envelope_id" => "e",
        "payload" => %{"type" => "block_actions", "actions" => ["not", "maps"]}
      }

      event = Event.from_socket_mode(env)
      assert Event.action_value(event) == nil
      assert Event.action_id(event) == nil
    end
  end
end
