defmodule Slink.Context do
  @moduledoc """
  The context passed to `c:Slink.handle_event/2`.

  Handlers are stateless; the context carries what they need to respond:

    * `:transport` — `:socket_mode` or `:http`, whichever delivered the event.
    * `:bot_token` — the bot token (`xoxb-…`) for Web API calls, e.g. via
      `send_message/3`. May be `nil` if the transport was started without one.
  """

  @enforce_keys [:transport]
  defstruct [:transport, :bot_token]

  @type t :: %__MODULE__{
          transport: :socket_mode | :http,
          bot_token: String.t() | nil
        }
end
