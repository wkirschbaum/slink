defmodule Slink.Event do
  @moduledoc """
  A Slack event, normalised into one shape regardless of transport.

  Socket Mode wraps events in an *envelope* (`events_api`, `slash_commands`,
  `interactive`) and expects an ACK; the Events API delivers the same inner
  payload over HTTP. Both are reduced here to the same struct so your
  `c:Slink.handle_event/2` never has to care which transport delivered it.

  ## Fields

    * `:type` — the routable type. For event callbacks this is the inner Slack
      event type (e.g. `"app_mention"`, `"message"`); otherwise the envelope
      kind (`"slash_commands"`, `"interactive"`, `"url_verification"`, ...).
    * `:subtype` — the event subtype, when present (e.g. `"bot_message"`).
    * `:payload` — the inner event/command/interaction map you'll usually read.
    * `:raw` — the full original map, if you need something not surfaced above.
    * `:transport` — `:socket_mode` or `:http`.
    * `:kind` — `:event_callback`, `:slash_commands`, `:interactive`, or `:other`.
    * `:envelope_id` — Socket Mode ACK id (nil over HTTP).
  """

  @type t :: %__MODULE__{
          type: atom() | String.t() | nil,
          subtype: String.t() | nil,
          payload: map(),
          raw: map(),
          transport: :socket_mode | :http,
          kind: :event_callback | :slash_commands | :interactive | :other,
          envelope_id: String.t() | nil
        }

  defstruct [:type, :subtype, :payload, :raw, :transport, :kind, :envelope_id]

  # Known Slack types are surfaced as atoms so handlers can match `:app_mention`
  # instead of `"app_mention"`. Unknown types stay as their raw string — we never
  # create atoms from arbitrary Slack input (unbounded atoms crash the VM). The
  # atoms below are created at compile time, so the runtime lookup is allocation
  # free.
  @known_types ~w(
    app_mention message
    reaction_added reaction_removed
    app_home_opened
    member_joined_channel member_left_channel
    team_join
    slash_commands interactive url_verification
  )a

  @type_map Map.new(@known_types, &{Atom.to_string(&1), &1})

  @doc "The atom for a known Slack `type` string, or the string itself if unknown."
  def normalize_type(nil), do: nil
  def normalize_type(type) when is_binary(type), do: Map.get(@type_map, type, type)

  @doc """
  The channel the event happened in, or `nil`.

  For `block_actions` interactions the channel is nested (and `payload["channel"]`
  is a map), so it's read from the interaction's `channel`/`container` instead.
  """
  def channel(%__MODULE__{kind: :interactive, payload: payload}),
    do: get_in(payload, ["channel", "id"]) || get_in(payload, ["container", "channel_id"])

  def channel(%__MODULE__{payload: payload}), do: payload["channel"]

  @doc "The event's text, or an empty string."
  def text(%__MODULE__{payload: payload}), do: payload["text"] || ""

  @doc "The user who produced the event (author of the message), or `nil`."
  def user(%__MODULE__{payload: payload}), do: payload["user"]

  # A Slack user mention in message text looks like `<@U0123ABCD>`, and sometimes
  # carries a label: `<@U0123ABCD|alice>`. Capture the id either way.
  @mention_re ~r/<@([A-Z0-9]+)(?:\|[^>]*)?>/

  @doc """
  Whether the app itself was mentioned — i.e. an `app_mention` event.

  This is the "someone @-mentioned the bot" signal. To see who *else* is
  mentioned in the text, use `mentions/1`.
  """
  def mention?(%__MODULE__{type: type}), do: type == :app_mention

  @doc """
  User IDs mentioned in the event's text, in order (e.g. `["U0123", "U0456"]`).

  Empty when nobody is mentioned.
  """
  def mentions(%__MODULE__{} = event) do
    @mention_re
    |> Regex.scan(text(event), capture: :all_but_first)
    |> List.flatten()
  end

  @doc "Whether `user_id` is mentioned in the event's text."
  def mentions?(%__MODULE__{} = event, user_id), do: user_id in mentions(event)

  @doc """
  The text addressed to the bot: the event's text with a leading `<@…>` mention
  stripped and trimmed.

  For `app_mention` events the text starts with the bot mention, so this returns
  just the instruction ("`@bot deploy now`" → "`deploy now`").
  """
  def command(%__MODULE__{} = event) do
    event
    |> text()
    |> String.replace(~r/^\s*<@[^>]+>\s*/, "")
    |> String.trim()
  end

  @doc """
  The event's own message timestamp (`ts`), or `nil`.

  For `block_actions` interactions this is the `ts` of the message the component
  is on (from the interaction's `message`/`container`).
  """
  def ts(%__MODULE__{kind: :interactive, payload: payload}),
    do: get_in(payload, ["message", "ts"]) || get_in(payload, ["container", "message_ts"])

  def ts(%__MODULE__{payload: payload}), do: payload["ts"]

  @doc """
  The thread this event belongs to, or `nil` if it's not in a thread.

  This is Slack's `thread_ts` — the `ts` of the thread's root message. For
  `block_actions` interactions it's read from the message the component is on, so
  a click in a thread threads and a click on a top-level message does not.
  """
  def thread_ts(%__MODULE__{kind: :interactive, payload: payload}),
    do: get_in(payload, ["message", "thread_ts"]) || get_in(payload, ["container", "thread_ts"])

  def thread_ts(%__MODULE__{payload: payload}), do: payload["thread_ts"]

  @doc "Whether this event happened inside a thread."
  def in_thread?(%__MODULE__{} = event), do: is_binary(thread_ts(event))

  @doc """
  Whether this event was produced by a bot (including this app itself).

  Slack tags bot-authored messages with a `bot_id`. Handlers use this to skip
  the bot's own posts so an auto-reply never triggers itself in a loop.
  """
  def from_bot?(%__MODULE__{payload: payload}), do: is_binary(payload["bot_id"])

  @doc """
  The `thread_ts` to reply into so a reply lands in this event's thread.

  If the event is already in a thread, that thread; otherwise the event's own
  `ts`, so replying *starts* a thread on it. `nil` if there's no timestamp.
  """
  def reply_thread(%__MODULE__{} = event), do: thread_ts(event) || ts(event)

  @doc "Normalise a decoded Socket Mode envelope."
  def from_socket_mode(%{"type" => "events_api"} = env) do
    event = get_in(env, ["payload", "event"]) || %{}

    %__MODULE__{
      type: normalize_type(event["type"]),
      subtype: event["subtype"],
      payload: event,
      raw: env,
      transport: :socket_mode,
      kind: :event_callback,
      envelope_id: env["envelope_id"]
    }
  end

  def from_socket_mode(%{"type" => type, "payload" => payload} = env)
      when type in ["slash_commands", "interactive"] do
    kind = %{"slash_commands" => :slash_commands, "interactive" => :interactive}

    %__MODULE__{
      type: normalize_type(type),
      payload: payload || %{},
      raw: env,
      transport: :socket_mode,
      kind: Map.fetch!(kind, type),
      envelope_id: env["envelope_id"]
    }
  end

  def from_socket_mode(env) do
    %__MODULE__{
      type: normalize_type(env["type"]),
      payload: env,
      raw: env,
      transport: :socket_mode,
      kind: :other,
      envelope_id: env["envelope_id"]
    }
  end

  @doc "Normalise a decoded Events API HTTP body."
  def from_http(%{"type" => "event_callback", "event" => event} = body) do
    %__MODULE__{
      type: normalize_type(event["type"]),
      subtype: event["subtype"],
      payload: event,
      raw: body,
      transport: :http,
      kind: :event_callback
    }
  end

  def from_http(body) do
    %__MODULE__{
      type: normalize_type(body["type"]),
      payload: body,
      raw: body,
      transport: :http,
      kind: :other
    }
  end
end
