defmodule Slink.Context do
  @moduledoc """
  The context passed to `c:Slink.handle_event/2`.

  Handlers are stateless; the context carries what they need to respond:

    * `:transport` — `:socket_mode` or `:http`, whichever delivered the event.
    * `:bot_token` — the bot token (`xoxb-…`) for Web API calls, e.g. via
      `send_message/4`. May be `nil` if the transport was started without one.
    * `:event` — the `Slink.Event` being handled. Carried here so `reply/3` needs
      only the context (channel and thread come from the event, the token from
      the context). Set by the dispatcher before your handler runs.
  """

  # The context is handed to user handlers, so it's an argument in any
  # handler-crash report (OTP blames the arguments). Keep the bot token out of
  # that output — the transports redact their own state via format_status/1, and
  # this closes the same leak on the handler side.
  @derive {Inspect, except: [:bot_token]}
  @enforce_keys [:transport]
  defstruct [:transport, :bot_token, :event]

  @type t :: %__MODULE__{
          transport: :socket_mode | :http,
          bot_token: String.t() | nil,
          event: Slink.Event.t() | nil
        }
end
