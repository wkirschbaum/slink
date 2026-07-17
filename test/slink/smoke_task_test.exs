defmodule Slink.SmokeTaskTest do
  # async: false — sets shared app env and process-global Mix shell.
  use ExUnit.Case, async: false

  setup do
    {:ok, base_url, pid} = Slink.Test.FakeWebApi.start()
    Application.put_env(:slink, :api_base_url, base_url)
    System.put_env("SLACK_BOT_TOKEN", "xoxb-smoke")
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      System.delete_env("SLACK_BOT_TOKEN")
      Application.delete_env(:slink, :api_base_url)
      Process.exit(pid, :normal)
    end)

    :ok
  end

  defp infos do
    Enum.reverse(collect_shell([]))
  end

  defp collect_shell(acc) do
    receive do
      {:mix_shell, :info, [msg]} -> collect_shell([msg | acc])
      {:mix_shell, :error, [msg]} -> collect_shell([msg | acc])
    after
      0 -> acc
    end
  end

  test "runs every step against the fake workspace and passes" do
    Mix.Tasks.Slink.Smoke.run(["C1"])

    output = Enum.join(infos(), "\n")
    assert output =~ "✓ auth.test: bot U-BOT"
    assert output =~ "✓ chat.postMessage"
    assert output =~ "✓ reactions.add"
    assert output =~ "✓ AI streaming"
    assert output =~ "✓ chat.update"
    assert output =~ "All required steps passed"
  end

  test "an unavailable AI surface is informational, not a failure" do
    Application.put_env(:slink, :api_caller, fn _token, method, _params ->
      case method do
        "chat.startStream" -> {:error, "unknown_method"}
        "auth.test" -> {:ok, %{"ok" => true, "user_id" => "U-BOT", "team_id" => "T1"}}
        "chat.postMessage" -> {:ok, %{"ok" => true, "ts" => "1.0"}}
        _other -> {:ok, %{"ok" => true}}
      end
    end)

    on_exit(fn -> Application.delete_env(:slink, :api_caller) end)

    Mix.Tasks.Slink.Smoke.run(["C1"])

    output = Enum.join(infos(), "\n")
    assert output =~ "AI streaming: not available"
    assert output =~ "fall back to plain messages"
    assert output =~ "All required steps passed"
  end

  test "a failing required step raises with the step named" do
    Application.put_env(:slink, :api_caller, fn _token, method, _params ->
      case method do
        "reactions.add" -> {:error, "missing_scope"}
        "auth.test" -> {:ok, %{"ok" => true, "user_id" => "U-BOT", "team_id" => "T1"}}
        "chat.postMessage" -> {:ok, %{"ok" => true, "ts" => "1.0"}}
        _other -> {:ok, %{"ok" => true}}
      end
    end)

    on_exit(fn -> Application.delete_env(:slink, :api_caller) end)

    assert_raise Mix.Error, ~r/reactions.add/, fn ->
      Mix.Tasks.Slink.Smoke.run(["C1"])
    end
  end

  test "requires a channel argument and a token" do
    assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Slink.Smoke.run([]) end

    System.delete_env("SLACK_BOT_TOKEN")

    assert_raise Mix.Error, ~r/SLACK_BOT_TOKEN/, fn ->
      Mix.Tasks.Slink.Smoke.run(["C1"])
    end
  end
end
