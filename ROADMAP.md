# Roadmap

Everything from the original roadmap has shipped:

- the OAuth install flow (`Slink.OAuth` + `Slink.OAuth.Plug`)
- Socket Mode high availability (`connections: N`)
- the public testing story (`Slink.Testing`)
- one-call file uploads (`Slink.API.upload_file/3`)
- Web API pagination (`Slink.API.stream/3`)
- Block Kit builders (`Slink.BlockKit`)
- AI-app support (assistant events, `set_status/2`, `stream_reply/3`)

## Known limitations (candidate future work)

- **Concurrent `view_submission` ACKs serialize in the Socket Mode transport.**
  Each synchronous modal-submit handler can hold the socket's GenServer for up
  to `:ack_timeout_ms` (default 2.5s), so two near-simultaneous submits can
  push the second past Slack's ~3s window. Fixing it means acking
  asynchronously (spawn the handler, send the ACK frame on completion).
- **`message_changed`-style subtypes are only partially normalised.**
  `Slink.Event.from_bot?/1` checks the nested message, but `ts/1`, `text/1`,
  `user/1` and `thread_ts/1` read the top level; handlers should guard on
  `event.subtype` for edits/deletes.
