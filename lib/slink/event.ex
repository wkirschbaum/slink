defmodule Slink.Event do
  @moduledoc """
  A Slack event, normalised into one shape regardless of transport.

  Socket Mode wraps events in an *envelope* (`events_api`, `slash_commands`,
  `interactive`) and expects an ACK; the Events API delivers the same inner
  payload over HTTP. Both are reduced here to the same struct so your
  `c:Slink.handle_event/2` never has to care which transport delivered it.

  ## Fields

    * `:type` — the type you match on, as an atom for known types. The inner
      Slack type for event callbacks (`:app_mention`, `:message`) and
      interactions (`:block_actions`, `:view_submission`, …), or the envelope
      kind otherwise (`:slash_commands`, `:url_verification`).
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
    block_actions view_submission view_closed shortcut message_action
  )a

  @type_map Map.new(@known_types, &{Atom.to_string(&1), &1})

  @doc "The atom for a known Slack `type` string, or the string itself if unknown."
  def normalize_type(nil), do: nil
  def normalize_type(type) when is_binary(type), do: Map.get(@type_map, type, type)
  # Slack always sends a string here, but a malformed frame might not — never crash.
  def normalize_type(_type), do: nil

  # Safe nested lookup: walk `keys`, returning nil the moment a level isn't a map.
  # Slack nests things (a `channel`, a `view`, an `item`) as maps, but a malformed
  # payload could put a string or a list there — `get_in/2` would raise on that,
  # and this code often runs in a transport process where a raise drops the
  # connection. `dig/2` degrades to nil instead. See `as_map/1` for the top level.
  defp dig(data, keys) do
    Enum.reduce_while(keys, data, fn
      key, acc when is_map(acc) -> {:cont, Map.get(acc, key)}
      _key, _acc -> {:halt, nil}
    end)
  end

  # Coerce a value to a map, so accessors can index it without raising. Slack
  # payloads are always objects, but a malformed frame might send a string, list,
  # or null where a map is expected.
  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  @doc """
  The channel the event happened in, or `nil`.

  For `block_actions` interactions the channel is nested (and `payload["channel"]`
  is a map), so it's read from the interaction's `channel`/`container` instead.
  """
  def channel(%__MODULE__{kind: :interactive, payload: payload}),
    do: dig(payload, ["channel", "id"]) || dig(payload, ["container", "channel_id"])

  def channel(%__MODULE__{kind: :slash_commands, payload: payload}), do: payload["channel_id"]

  def channel(%__MODULE__{type: type, payload: payload})
      when type in [:reaction_added, :reaction_removed],
      do: dig(payload, ["item", "channel"])

  def channel(%__MODULE__{payload: payload}), do: payload["channel"]

  @doc "The event's text, or an empty string."
  def text(%__MODULE__{payload: payload}) do
    case payload["text"] do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  @doc """
  The user who produced the event, or `nil`.

  Interactions nest the user as a map (`user.id`) and slash commands carry a
  flat `user_id`; both are surfaced here as the plain user id, like message
  events.
  """
  def user(%__MODULE__{kind: :interactive, payload: payload}), do: dig(payload, ["user", "id"])
  def user(%__MODULE__{kind: :slash_commands, payload: payload}), do: payload["user_id"]
  def user(%__MODULE__{payload: payload}), do: payload["user"]

  # A Slack user mention in message text looks like `<@U0123ABCD>`, and sometimes
  # carries a label: `<@U0123ABCD|alice>`. Capture the id either way.
  @mention_re ~r/<@([A-Z0-9]+)(?:\|[^>]*)?>/

  @doc """
  Whether the app itself was mentioned — i.e. an `app_mention` event.

  This is the "someone @-mentioned the bot" signal. To see who *else* is
  mentioned in the text, use `mentions/1` (note the plural).
  """
  def app_mention?(%__MODULE__{type: type}), do: type == :app_mention

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
  The text addressed to the bot: the event's text with Slack's link/mention
  markup reduced to the plain text a human typed, then trimmed.

  Slack wraps links and mentions in angle brackets — `<@U123|alice>` (user),
  `<#C1|general>` (channel), `<!here>` (special), `<mailto:a@b.com|a@b.com>`,
  `<https://x|label>` (url). Each is unwrapped so the command reads naturally: a
  user/channel becomes its name, a `mailto:` becomes the bare address (so an
  email address "picks up" as plain text), a url stays the url, and a bare
  `<@U123>` — such as the bot's own mention at the start of an `app_mention` —
  drops out. So "`@bot deploy now`" → "`deploy now`" and a linkified
  "`@bot <mailto:a@b.com|a@b.com>`" → "`a@b.com`".
  """
  def command(%__MODULE__{} = event) do
    event
    |> text()
    |> unwrap_markup()
    |> String.trim()
  end

  # Reduce each `<…>` Slack entity to its plain-text form (see command/1).
  defp unwrap_markup(text) do
    Regex.replace(~r/<([^<>]+)>/, text, fn _match, inner ->
      {target, label} =
        case String.split(inner, "|", parts: 2) do
          [t, l] -> {t, l}
          [t] -> {t, nil}
        end

      cond do
        String.starts_with?(target, "mailto:") -> String.replace_prefix(target, "mailto:", "")
        String.starts_with?(target, "@") -> label || ""
        String.starts_with?(target, "#") -> label || ""
        String.starts_with?(target, "!") -> label || String.replace_prefix(target, "!", "")
        true -> target
      end
    end)
  end

  @doc """
  The event's own message timestamp (`ts`), or `nil`.

  For `block_actions` interactions this is the `ts` of the message the component
  is on (from the interaction's `message`/`container`). For `reaction_added`/
  `reaction_removed` it's the `ts` of the reacted-to item.
  """
  def ts(%__MODULE__{kind: :interactive, payload: payload}),
    do: dig(payload, ["message", "ts"]) || dig(payload, ["container", "message_ts"])

  def ts(%__MODULE__{type: type, payload: payload})
      when type in [:reaction_added, :reaction_removed],
      do: dig(payload, ["item", "ts"])

  def ts(%__MODULE__{payload: payload}), do: payload["ts"]

  @doc """
  The thread this event belongs to, or `nil` if it's not in a thread.

  This is Slack's `thread_ts` — the `ts` of the thread's root message. For
  `block_actions` interactions it's read from the message the component is on, so
  a click in a thread threads and a click on a top-level message does not.
  """
  def thread_ts(%__MODULE__{kind: :interactive, payload: payload}),
    do: dig(payload, ["message", "thread_ts"]) || dig(payload, ["container", "thread_ts"])

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

  @doc "The slash command name, e.g. `\"/deploy\"` (slash commands only), or `nil`."
  def command_name(%__MODULE__{payload: payload}), do: payload["command"]

  @doc """
  The short-lived `response_url` a slash command or interaction carries, or `nil`.

  Valid for ~30 minutes and up to 5 posts; use it with `Slink.API.respond/2` (or
  just `reply/3`, which routes there automatically for these events).
  """
  def response_url(%__MODULE__{payload: payload}), do: payload["response_url"]

  @doc """
  The `trigger_id` needed to open a modal in response to this event, or `nil`.

  Present on slash commands and most interactions; valid for only ~3 seconds.
  """
  def trigger_id(%__MODULE__{payload: payload}), do: payload["trigger_id"]

  @doc "The list of actions in a `block_actions` interaction (empty otherwise)."
  def actions(%__MODULE__{payload: payload}) do
    case payload["actions"] do
      actions when is_list(actions) -> actions
      _ -> []
    end
  end

  @doc "The `action_id` of the first action in a `block_actions` interaction, or `nil`."
  def action_id(%__MODULE__{} = event) do
    case actions(event) do
      [%{"action_id" => id} | _] -> id
      _ -> nil
    end
  end

  @doc """
  The value of the first action, or `nil`.

  Handles a button's `value` and a select menu's `selected_option.value`.
  """
  def action_value(%__MODULE__{} = event) do
    case actions(event) do
      [action | _] when is_map(action) ->
        action["value"] || dig(action, ["selected_option", "value"])

      _ ->
        nil
    end
  end

  @doc "The `callback_id` of a shortcut / message action / view, or `nil`."
  def callback_id(%__MODULE__{payload: payload}),
    do: payload["callback_id"] || dig(payload, ["view", "callback_id"])

  @doc "The `view` map of a `view_submission` / `view_closed` interaction, or `nil`."
  def view(%__MODULE__{payload: payload}), do: payload["view"]

  @doc "A modal's submitted input values (`view.state.values`), or `%{}`."
  def view_values(%__MODULE__{payload: payload}),
    do: dig(payload, ["view", "state", "values"]) || %{}

  @doc """
  Slack's per-event id (`event_id`) for an event callback, or `nil`.

  Stable across Slack's retries of the same event, so it's the dedup key (see
  `Slink.Dedup`). Only event callbacks carry one — slash commands and
  interactions return `nil`.
  """
  def event_id(%__MODULE__{transport: :socket_mode, raw: raw}),
    do: dig(raw, ["payload", "event_id"])

  def event_id(%__MODULE__{raw: raw}), do: dig(raw, ["event_id"])

  @doc """
  Slack's retry attempt number for this delivery (`0` for a first delivery).

  Socket Mode carries it on the envelope; over HTTP the plug stashes the
  `X-Slack-Retry-Num` header into the body so it's visible here too.
  """
  def retry_attempt(%__MODULE__{transport: :socket_mode, raw: raw}),
    do: dig(raw, ["retry_attempt"]) || 0

  def retry_attempt(%__MODULE__{raw: raw}), do: dig(raw, ["retry_num"]) || 0

  @doc "Whether Slack flagged this as a retry of an earlier delivery."
  def retry?(%__MODULE__{} = event), do: retry_attempt(event) > 0

  @doc "Normalise a decoded Socket Mode envelope."
  def from_socket_mode(%{"type" => "events_api"} = env) do
    event = as_map(dig(env, ["payload", "event"]))

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
    payload = as_map(payload)

    %__MODULE__{
      # For interactions, route on the inner kind (`:block_actions`,
      # `:view_submission`, …) rather than the envelope's `"interactive"`.
      type: envelope_type(type, payload),
      payload: payload,
      raw: env,
      transport: :socket_mode,
      kind: if(type == "slash_commands", do: :slash_commands, else: :interactive),
      envelope_id: env["envelope_id"]
    }
  end

  def from_socket_mode(env) do
    env = as_map(env)

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
    event = as_map(event)

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
    body = as_map(body)

    %__MODULE__{
      type: normalize_type(body["type"]),
      payload: body,
      raw: body,
      transport: :http,
      kind: :other
    }
  end

  @doc """
  Normalise a decoded `application/x-www-form-urlencoded` body.

  Slack delivers slash commands and interactions over HTTP as a form, not JSON.
  Interactions carry a single `"payload"` field holding JSON (decoded here);
  anything else is a slash command whose form fields *are* the payload.
  """
  def from_http_form(%{"payload" => json}) when is_binary(json) do
    payload =
      case JSON.decode(json) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    %__MODULE__{
      type: normalize_type(payload["type"]),
      payload: payload,
      raw: %{"payload" => payload},
      transport: :http,
      kind: :interactive
    }
  end

  def from_http_form(params) when is_map(params) do
    %__MODULE__{
      type: :slash_commands,
      payload: params,
      raw: params,
      transport: :http,
      kind: :slash_commands
    }
  end

  # A form body always decodes to a map, but keep this total for any caller.
  def from_http_form(other) do
    %__MODULE__{payload: %{}, raw: as_map(other), transport: :http, kind: :other}
  end

  # Route interactions on their inner kind; slash commands keep the envelope kind.
  defp envelope_type("slash_commands", _payload), do: :slash_commands
  defp envelope_type("interactive", payload), do: normalize_type(payload["type"])
end
