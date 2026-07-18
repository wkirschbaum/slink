defmodule Slink.Playground do
  @moduledoc """
  A local fake Slack — try your bot from the browser, without a workspace.

  The playground serves a Slack-like web UI on localhost. Messages you type,
  slash commands you run, buttons you click and modals you submit are dispatched
  to your bot as real events through the production pipeline, and every Web API
  call your bot makes lands in the fake workspace and appears live in the page —
  including threads, ephemeral messages, reactions, Block Kit, modals, the App
  Home tab and streamed replies. An inspector shows each raw event and API call.

  ## Enabling it

  The playground is **compiled out of slink by default**. Opt in from your dev
  config, and add Bandit (slink's optional HTTP server) to your deps:

      # config/dev.exs
      config :slink, playground: true

      # mix.exs
      {:bandit, "~> 1.12", only: :dev}

  Changing the flag changes slink's compile-time config, so Mix will ask you to
  recompile it (`mix deps.compile slink --force`). Then start the playground in
  your dev supervision tree — typically *instead of* `Slink.SocketMode`:

      children = [
        {Slink.Playground, module: MyBot, port: 4040}
      ]

  and open [http://localhost:4040](http://localhost:4040).

  ## Options

    * `:module` — required, your `Slink` handler module.
    * `:port` — default `4040`. `0` picks a free port (see `url/1`).
    * `:bot_token` — the fake bot token in handler contexts, default
      `"xoxb-playground"`.
    * `:name` — registered name, default `Slink.Playground`.

  ## How faithful is it?

  Inbound events are Socket-Mode envelopes run through the same normaliser and
  dispatcher as production, and outbound calls go over real HTTP through the
  real rate limiter — the playground boots by pointing `config :slink,
  :api_base_url` at itself (VM-global while it runs, restored on shutdown; a
  warning is logged if a real transport is in the same VM). Replies pace at
  Slack's ~1
  message/second/channel; lower `config :slink, :rate_interval_ms` if that
  slows your dev loop. See the [Playground guide](playground.html) for the
  full fidelity notes.

  **Dev only.** The server binds to 127.0.0.1 and has no authentication.
  """

  @enabled Application.compile_env(:slink, :playground, false)

  if @enabled do
    use Supervisor
    require Logger

    def start_link(opts) do
      unless Code.ensure_loaded?(Bandit) do
        raise ArgumentError,
              "Slink.Playground needs the optional :bandit dependency; add " <>
                ~s({:bandit, "~> 1.12", only: :dev} to your deps)
      end

      name = Keyword.get(opts, :name, __MODULE__)

      with {:ok, pid} <- Supervisor.start_link(__MODULE__, opts, name: name) do
        finish_boot(pid, name, opts)
        {:ok, pid}
      end
    end

    def child_spec(opts) do
      %{
        id: Keyword.get(opts, :name, __MODULE__),
        start: {__MODULE__, :start_link, [opts]},
        type: :supervisor
      }
    end

    @impl true
    def init(opts) do
      workspace = workspace_name(Keyword.get(opts, :name, __MODULE__))

      children = [
        {Slink.Playground.Workspace,
         name: workspace,
         module: Keyword.fetch!(opts, :module),
         bot_token: Keyword.get(opts, :bot_token, "xoxb-playground")},
        Supervisor.child_spec(
          {Bandit,
           plug: {Slink.Playground.Router, workspace: workspace},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: Keyword.get(opts, :port, 4040)},
          id: :listener
        )
      ]

      Supervisor.init(children, strategy: :rest_for_one)
    end

    @doc "The playground's URL (useful with `port: 0`)."
    def url(name \\ __MODULE__) do
      Slink.Playground.Workspace.info(workspace_name(name)).base_url
    end

    # The listener is up; now we know the port. Point the workspace's minted
    # URLs and the bot's Web API traffic at it, then resolve the bot identity
    # through the fake auth.test so mentions_me?/1 and mention synthesis work.
    defp finish_boot(sup, name, opts) do
      {_, pid, _, _} = sup |> Supervisor.which_children() |> List.keyfind(:listener, 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      base = "http://127.0.0.1:#{port}"

      workspace = workspace_name(name)
      api_env_before = Application.get_env(:slink, :api_base_url)

      if api_env_before do
        Logger.warning(
          "Slink.Playground: overriding :api_base_url (was #{inspect(api_env_before)}) — " <>
            "restored when the playground stops"
        )
      end

      # The workspace remembers the previous value and restores it on shutdown.
      :ok = Slink.Playground.Workspace.set_base_url(workspace, base, api_env_before)
      Application.put_env(:slink, :api_base_url, base <> "/api")

      if Process.whereis(Slink.SocketMode) do
        Logger.warning(
          "Slink.Playground: a Slink.SocketMode client is running in this VM; " <>
            "its Web API calls will hit the playground, not Slack"
        )
      end

      Slink.Identity.prewarm(Keyword.get(opts, :bot_token, "xoxb-playground"))
      Logger.info("Slink.Playground: your workspace is at #{base}")
    end

    defp workspace_name(name), do: Module.concat(name, Workspace)
  else
    @message "Slink.Playground is compiled out by default. Add " <>
               "`config :slink, playground: true` to config/dev.exs, recompile slink " <>
               "(`mix deps.compile slink --force`), and see the Slink.Playground docs"

    def start_link(_opts), do: raise(ArgumentError, @message)

    def child_spec(_opts), do: raise(ArgumentError, @message)

    @doc "The playground's URL (useful with `port: 0`)."
    def url(_name \\ nil), do: raise(ArgumentError, @message)
  end
end
