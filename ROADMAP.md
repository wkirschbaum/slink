# Roadmap

Everything from the original roadmap has shipped:

- the OAuth install flow (`Slink.OAuth` + `Slink.OAuth.Plug`)
- Socket Mode high availability (`connections: N`)
- the public testing story (`Slink.Testing`)
- one-call file uploads (`Slink.API.upload_file/3`)
- Web API pagination (`Slink.API.stream/3`)
- Block Kit builders (`Slink.BlockKit`)
- AI-app support (assistant events, `set_status/2`, `stream_reply/3`)

Former known limitations, both since fixed: concurrent `view_submission` ACKs
no longer serialize in the Socket Mode transport (handlers run off-process and
ACK on completion), and `message_changed`/`message_deleted` subtypes are fully
normalised (`text/1`, `user/1`, `ts/1`, `thread_ts/1` and `from_bot?/1` read
the nested message).

Nothing is currently planned. Ideas welcome — open an issue.
