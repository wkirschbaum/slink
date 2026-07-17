defmodule Slink.MixProject do
  use Mix.Project

  @version "0.6.0"
  @source_url "https://github.com/wkirschbaum/slink"

  def project do
    [
      app: :slink,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [
        # Test-support servers aren't library code; measure coverage of lib/ only.
        ignore_modules: [~r/^Slink\.Test\./],
        # Threshold below 100 on purpose: the uncovered lines are defensive error
        # branches (Mint encode/decode/transport failures) that need fault
        # injection, plus a little jitter from handlers running in Tasks. All
        # behaviour paths are covered; see the SocketMode tests.
        summary: [threshold: 82]
      ],
      deps: deps(),
      name: "Slink",
      description:
        "A lightweight Slack bot toolkit for Elixir — Socket Mode and Events API on one core.",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Slink.Application, []}
    ]
  end

  # The example bot ships as a runnable reference, not as library code.
  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(:test), do: ["lib", "examples", "test/support"]
  defp elixirc_paths(_), do: ["lib", "examples"]

  defp deps do
    [
      {:req, "~> 0.6"},
      {:mint_web_socket, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.20"},
      # Optional: only needed if you run the Events API adapter as a standalone server.
      {:bandit, "~> 1.12", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Test-only: stand up a local fake-Slack WebSocket server to prove the Socket Mode path.
      {:websock_adapter, "~> 0.5", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["Wilhelm Kirschbaum"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        {"guides/interactivity.md", [title: "Slash commands, buttons & modals"]},
        {"guides/composing.md", [title: "Composing helpers"]},
        {"guides/ai-apps.md", [title: "AI apps"]},
        {"guides/multi-workspace.md", [title: "Serving many workspaces"]},
        {"guides/testing.md", [title: "Testing your bot"]},
        {"guides/production.md", [title: "Going to production"]},
        "CHANGELOG.md",
        "ROADMAP.md",
        {:LICENSE, [title: "License"]}
      ],
      groups_for_extras: [Guides: ~r{guides/}],
      groups_for_modules: [
        Transports: [Slink.SocketMode, Slink.EventsApi.Plug],
        "Web API": [Slink.API, Slink.API.Error, Slink.Rate, Slink.Rate.Channel, Slink.Identity],
        Events: [Slink.Event, Slink.Context, Slink.Dedup],
        "Block Kit": [Slink.BlockKit],
        Installation: [Slink.OAuth, Slink.OAuth.Install, Slink.OAuth.Plug],
        Testing: [Slink.Testing, Slink.Testing.Run],
        Examples: [Slink.ExampleBot]
      ]
    ]
  end
end
