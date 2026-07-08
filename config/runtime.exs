import Config

# Example: read Slack credentials from the environment at runtime.
#
#   export SLACK_APP_TOKEN=xapp-...      # app-level token (connections:write) — Socket Mode
#   export SLACK_BOT_TOKEN=xoxb-...      # bot token — Web API calls
#   export SLACK_SIGNING_SECRET=...      # Events API request verification
#
# config :slink,
#   app_token: System.get_env("SLACK_APP_TOKEN"),
#   bot_token: System.get_env("SLACK_BOT_TOKEN"),
#   signing_secret: System.get_env("SLACK_SIGNING_SECRET")
