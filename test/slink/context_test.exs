defmodule Slink.ContextTest do
  use ExUnit.Case, async: true

  alias Slink.Context

  test "inspecting a context never reveals the bot token" do
    ctx = %Context{transport: :http, bot_token: "xoxb-super-secret", event: nil}

    rendered = inspect(ctx)

    refute rendered =~ "xoxb-super-secret"
    # The other fields still render (only the token is dropped).
    assert rendered =~ "transport: :http"
  end
end
