defmodule Slink.IdentityTest do
  # async: false — sets the shared :identity_fetch app env.
  use ExUnit.Case, async: false

  alias Slink.Identity

  setup do
    on_exit(fn ->
      # Restore the network-off default from test_helper.exs.
      Application.put_env(:slink, :identity_fetch, fn _token -> {:error, :not_stubbed} end)
    end)

    :ok
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  test "bot_user_id/1 is nil until a prewarm lands, then the cached id" do
    Application.put_env(:slink, :identity_fetch, fn _token ->
      {:ok, %{"user_id" => "U-CACHED", "team_id" => "T1"}}
    end)

    token = "xoxb-identity-#{System.unique_integer([:positive])}"
    assert Identity.bot_user_id(token) == nil

    assert :ok = Identity.prewarm(token)
    wait_until(fn -> Identity.bot_user_id(token) == "U-CACHED" end)
  end

  test "a failed fetch stays uncached, so a later prewarm retries and succeeds" do
    Application.put_env(:slink, :identity_fetch, fn _token -> {:error, :slack_down} end)

    token = "xoxb-identity-#{System.unique_integer([:positive])}"
    Identity.prewarm(token)

    # Give the failing task a moment; the id must still be unknown.
    Process.sleep(50)
    assert Identity.bot_user_id(token) == nil

    Application.put_env(:slink, :identity_fetch, fn _token ->
      {:ok, %{"user_id" => "U-RETRY"}}
    end)

    Identity.prewarm(token)
    wait_until(fn -> Identity.bot_user_id(token) == "U-RETRY" end)
  end

  test "nil tokens are a no-op" do
    assert Identity.bot_user_id(nil) == nil
    assert Identity.prewarm(nil) == :ok
  end

  test "the raw token never sits in the cache table" do
    Application.put_env(:slink, :identity_fetch, fn _token -> {:ok, %{"user_id" => "U-X"}} end)

    token = "xoxb-identity-secret-#{System.unique_integer([:positive])}"
    Identity.prewarm(token)
    wait_until(fn -> Identity.bot_user_id(token) == "U-X" end)

    refute :ets.tab2list(Slink.Identity) |> inspect() =~ token
  end
end
