defmodule Mix.Tasks.Slink.Smoke do
  @shortdoc "Live smoke test of your Slack app: identity, posting, reactions, AI streaming"

  @moduledoc """
  Verifies a real workspace end to end — `auth.test`, but for everything Slink
  uses, including whether the **AI streaming surface** is enabled for the app.

      SLACK_BOT_TOKEN=xoxb-... mix slink.smoke C0123456789

  It posts a couple of test messages to the given channel (invite the bot
  first), so point it at a private testing channel. Steps:

    1. `auth.test` — who the token is.
    2. `chat.postMessage` — the base test message.
    3. `reactions.add` / `reactions.remove` — what `working/3` needs.
    4. `chat.startStream` → `appendStream` → `stopStream` into the test
       message's thread — **informational**: reports whether AI streaming
       (`stream_reply/3`) is available; many apps simply don't have the
       feature enabled, which is fine.
    5. `chat.update` — marks the test message done.

  Each step prints its result; the task exits non-zero if a required step
  fails. For offline handler tests, use `Slink.Testing` instead — this task is
  the live half of the story.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    channel =
      case argv do
        [channel] -> channel
        _ -> Mix.raise("usage: SLACK_BOT_TOKEN=xoxb-... mix slink.smoke CHANNEL_ID")
      end

    token =
      System.get_env("SLACK_BOT_TOKEN") ||
        Mix.raise("SLACK_BOT_TOKEN is not set (a bot token, xoxb-…)")

    failures =
      []
      |> required("auth.test", fn ->
        with {:ok, body} <- Slink.API.auth_test(token) do
          {:ok, "bot #{body["user_id"]} in team #{body["team_id"]} (#{body["team"]})"}
        end
      end)
      |> smoke_message(token, channel)

    case failures do
      [] ->
        Mix.shell().info("\nAll required steps passed. ✅")

      steps ->
        Mix.raise("smoke test failed at: #{Enum.join(Enum.reverse(steps), ", ")}")
    end
  end

  defp smoke_message(failures, token, channel) do
    case Slink.API.post_message(token, channel, "slink smoke test 🔧") do
      {:ok, %{"ts" => ts}} ->
        report("chat.postMessage", {:ok, "ts #{ts}"})

        failures
        |> required("reactions.add", fn ->
          Slink.API.add_reaction(token, channel, ts, "eyes")
        end)
        |> required("reactions.remove", fn ->
          Slink.API.remove_reaction(token, channel, ts, "eyes")
        end)
        |> ai_streaming(token, channel, ts)
        |> required("chat.update", fn ->
          Slink.API.update_message(token, channel, ts, "slink smoke test ✅ done")
        end)

      {:error, reason} ->
        report("chat.postMessage", {:error, reason})
        # Nothing downstream can run without the base message.
        ["chat.postMessage" | failures]
    end
  end

  # Informational: absence of the streaming feature is a finding, not a failure.
  defp ai_streaming(failures, token, channel, thread_ts) do
    result =
      with {:ok, %{"ts" => ts}} <- Slink.API.start_stream(token, channel, thread_ts),
           {:ok, _} <- Slink.API.append_stream(token, channel, ts, "streaming works ✅") do
        Slink.API.stop_stream(token, channel, ts)
      end

    case result do
      {:ok, _} ->
        report(
          "AI streaming (chat.startStream trio)",
          {:ok, "enabled — stream_reply/3 will stream"}
        )

      {:error, reason} ->
        Mix.shell().info(
          "· AI streaming: not available (#{inspect(reason)}) — stream_reply/3 will " <>
            "fall back to plain messages. Enable the Agents feature + assistant:write to stream."
        )
    end

    failures
  end

  defp required(failures, step, fun) do
    case report(step, fun.()) do
      :ok -> failures
      :error -> [step | failures]
    end
  end

  defp report(step, result) do
    case result do
      {:ok, note} when is_binary(note) ->
        Mix.shell().info("✓ #{step}: #{note}")
        :ok

      {:ok, _body} ->
        Mix.shell().info("✓ #{step}")
        :ok

      {:error, reason} ->
        Mix.shell().error("✗ #{step}: #{inspect(reason)}")
        :error
    end
  end
end
