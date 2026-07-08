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
          type: String.t() | nil,
          subtype: String.t() | nil,
          payload: map(),
          raw: map(),
          transport: :socket_mode | :http,
          kind: :event_callback | :slash_commands | :interactive | :other,
          envelope_id: String.t() | nil
        }

  defstruct [:type, :subtype, :payload, :raw, :transport, :kind, :envelope_id]

  @doc "The channel the event happened in, or `nil`."
  @spec channel(t()) :: String.t() | nil
  def channel(%__MODULE__{payload: payload}), do: payload["channel"]

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
      type: event["type"],
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
      type: type,
      payload: payload || %{},
      raw: env,
      transport: :socket_mode,
      kind: Map.fetch!(kind, type),
      envelope_id: env["envelope_id"]
    }
  end

  def from_socket_mode(env) do
    %__MODULE__{
      type: env["type"],
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
      type: event["type"],
      subtype: event["subtype"],
      payload: event,
      raw: body,
      transport: :http,
      kind: :event_callback
    }
  end

  def from_http(body) do
    %__MODULE__{
      type: body["type"],
      payload: body,
      raw: body,
      transport: :http,
      kind: :other
    }
  end
end
