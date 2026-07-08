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
  @spec normalize_type(String.t() | nil) :: atom() | String.t() | nil
  def normalize_type(nil), do: nil
  def normalize_type(type) when is_binary(type), do: Map.get(@type_map, type, type)

  @doc "The channel the event happened in, or `nil`."
  @spec channel(t()) :: String.t() | nil
  def channel(%__MODULE__{payload: payload}), do: payload["channel"]

  @doc "The event's text, or an empty string."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{payload: payload}), do: payload["text"] || ""

  @doc "The user who produced the event (author of the message), or `nil`."
  @spec user(t()) :: String.t() | nil
  def user(%__MODULE__{payload: payload}), do: payload["user"]

  # A Slack user mention in message text looks like `<@U0123ABCD>`, and sometimes
  # carries a label: `<@U0123ABCD|alice>`. Capture the id either way.
  @mention_re ~r/<@([A-Z0-9]+)(?:\|[^>]*)?>/

  @doc """
  Whether the app itself was mentioned — i.e. an `app_mention` event.

  This is the "someone @-mentioned the bot" signal. To see who *else* is
  mentioned in the text, use `mentions/1`.
  """
  @spec mention?(t()) :: boolean()
  def mention?(%__MODULE__{type: type}), do: type == :app_mention

  @doc """
  User IDs mentioned in the event's text, in order (e.g. `["U0123", "U0456"]`).

  Empty when nobody is mentioned.
  """
  @spec mentions(t()) :: [String.t()]
  def mentions(%__MODULE__{} = event) do
    @mention_re
    |> Regex.scan(text(event), capture: :all_but_first)
    |> List.flatten()
  end

  @doc "Whether `user_id` is mentioned in the event's text."
  @spec mentions?(t(), String.t()) :: boolean()
  def mentions?(%__MODULE__{} = event, user_id), do: user_id in mentions(event)

  @doc """
  The text addressed to the bot: the event's text with a leading `<@…>` mention
  stripped and trimmed.

  For `app_mention` events the text starts with the bot mention, so this returns
  just the instruction ("`@bot deploy now`" → "`deploy now`").
  """
  @spec command(t()) :: String.t()
  def command(%__MODULE__{} = event) do
    event
    |> text()
    |> String.replace(~r/^\s*<@[^>]+>\s*/, "")
    |> String.trim()
  end

  @doc "The event's own message timestamp (`ts`), or `nil`."
  @spec ts(t()) :: String.t() | nil
  def ts(%__MODULE__{payload: payload}), do: payload["ts"]

  @doc """
  The thread this event belongs to, or `nil` if it's not in a thread.

  This is Slack's `thread_ts` — the `ts` of the thread's root message.
  """
  @spec thread_ts(t()) :: String.t() | nil
  def thread_ts(%__MODULE__{payload: payload}), do: payload["thread_ts"]

  @doc "Whether this event happened inside a thread."
  @spec in_thread?(t()) :: boolean()
  def in_thread?(%__MODULE__{} = event), do: is_binary(thread_ts(event))

  @doc """
  Whether this event was produced by a bot (including this app itself).

  Slack tags bot-authored messages with a `bot_id`. Handlers use this to skip
  the bot's own posts so an auto-reply never triggers itself in a loop.
  """
  @spec from_bot?(t()) :: boolean()
  def from_bot?(%__MODULE__{payload: payload}), do: is_binary(payload["bot_id"])

  @doc """
  The `thread_ts` to reply into so a reply lands in this event's thread.

  If the event is already in a thread, that thread; otherwise the event's own
  `ts`, so replying *starts* a thread on it. `nil` if there's no timestamp.
  """
  @spec reply_thread(t()) :: String.t() | nil
  def reply_thread(%__MODULE__{} = event), do: thread_ts(event) || ts(event)

  @doc "Normalise a decoded Socket Mode envelope."
  @spec from_socket_mode(map()) :: t()
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
  @spec from_http(map()) :: t()
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
