defmodule SlinkTest do
  use ExUnit.Case, async: true

  alias Slink.Event

  describe "enabled?/1" do
    test "true only when enabled and both tokens are present" do
      assert Slink.enabled?(enabled: true, app_token: "xapp", bot_token: "xoxb")
    end

    test "false when disabled" do
      refute Slink.enabled?(enabled: false, app_token: "xapp", bot_token: "xoxb")
    end

    test "false when a token is missing" do
      refute Slink.enabled?(enabled: true, app_token: "xapp")
      refute Slink.enabled?(enabled: true, bot_token: "xoxb")
    end

    test "false on empty config, and coerces to a real boolean" do
      assert Slink.enabled?([]) === false
      assert Slink.enabled?(%{enabled: true, app_token: "xapp", bot_token: "xoxb"}) === true
    end
  end

  describe "in_thread?/1 (delegates to Slink.Event)" do
    test "true when the event carries a thread_ts" do
      event = %Event{payload: %{"thread_ts" => "1.0"}, raw: %{}, transport: :socket_mode}
      assert Slink.in_thread?(event)
    end

    test "false when it does not" do
      event = %Event{payload: %{"ts" => "2.0"}, raw: %{}, transport: :socket_mode}
      refute Slink.in_thread?(event)
    end
  end
end
