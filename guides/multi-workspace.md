# Serving many workspaces — routing & the OAuth install flow

Slink is token-per-request throughout: every `Slink.API` call takes a token,
the handler context carries the `:bot_token`, and both transports let you pick
it per workspace. One bot module serves them all; two things are yours to
wire — *routing* to stored tokens, and *acquiring* them as workspaces install.

## Routing

Over HTTP, pass a 1-arity `:bot_token` resolver — it's called with the
event's team id (`Slink.Event.team_id/1`), so you look the token up from your
own store. The signing secret is per-*app* and stays a single value:

```elixir
forward "/slack/events", to: Slink.EventsApi.Plug,
  init_opts: [
    module: MyBot,
    signing_secret: fn -> System.fetch_env!("SLACK_SIGNING_SECRET") end,
    bot_token: fn team_id -> MyApp.Installs.bot_token(team_id) end
  ]
```

Over Socket Mode, run one client per workspace, each with its own tokens and
a distinct `:name`:

```elixir
for w <- MyApp.workspaces() do
  {Slink.SocketMode,
   name: {:global, {MyBot, w.team_id}},
   module: MyBot,
   app_token: w.app_token,
   bot_token: w.bot_token}
end
```

## Acquiring tokens: the OAuth install flow

Send installers to Slack's consent screen, and mount the callback plug at the
app's Redirect URL — it exchanges the returned code and hands the result to
your store:

```elixir
# The "Add to Slack" link:
Slink.OAuth.authorize_url(
  client_id: client_id,
  scopes: ~w(app_mentions:read chat:write commands),
  redirect_uri: "https://example.com/slack/oauth/callback",
  state: my_csrf_token
)

# The callback endpoint:
forward "/slack/oauth/callback", to: Slink.OAuth.Plug,
  init_opts: [
    client_id: client_id,
    client_secret: fn -> System.fetch_env!("SLACK_CLIENT_SECRET") end,
    verify_state: fn state -> MyApp.valid_csrf?(state) end,
    install: fn %Slink.OAuth.Install{} = install ->
      MyApp.Installs.put(install.team_id, install.bot_token)
    end
  ]
```

The `:install` callback receives a normalised `Slink.OAuth.Install` (team
id/name, bot token, bot user id, enterprise id, Slack's full response in
`raw`) and **must return `:ok`** — anything else, or a raise, answers the
installer with a 500 rather than claiming success. The plug also handles the
cancelled-consent redirect and a `:redirect_to` success redirect; exchange
failures and callback crashes are contained without leaking tokens into logs.

Persistence is deliberately yours: store `{team_id, bot_token}` however you
like, prune on `:tokens_revoked` / `:app_uninstalled` events (both arrive as
atoms), and hand the token back per request via the resolver above.

## Uninstalls

```elixir
def handle_event(%Slink.Event{type: :app_uninstalled} = event, _context) do
  MyApp.Installs.delete(Slink.Event.team_id(event))
end
```
