import Config

# Slink itself needs no compile-time config. Read your tokens at runtime instead
# (see config/runtime.exs) and pass them to Slink.SocketMode / Slink.EventsApi.Plug.

# The playground (a local fake-Slack web UI) is compiled out by default; slink's
# own dev and test builds enable it so it can be developed and tested here.
if config_env() in [:dev, :test] do
  config :slink, playground: true
end
