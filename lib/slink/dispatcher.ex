defmodule Slink.Dispatcher do
  @moduledoc false
  require Logger

  alias Slink.Event

  @default_ack_timeout_ms 2_500

  @doc """
  Dispatch `event` to `module` off-process, under `Slink.TaskSupervisor`.

  This is the single path both transports use after they've acknowledged the
  event to Slack. Crash containment is the task's job — a handler that raises
  kills only its own (temporary) task; the transport keeps running.

  A delivery Slack is retrying (same `event_id`) is dropped here, so a handler
  never fires twice for one event — see `Slink.Dedup`.
  """
  def async(module, %Event{} = event, %Slink.Context{} = context) do
    emit_received(module, event, context)

    if duplicate?(module, event) do
      Logger.debug("Slink: dropping duplicate delivery of #{Event.event_id(event)}")
    else
      case Task.Supervisor.start_child(task_supervisor(), fn ->
             dispatch(module, event, context)
           end) do
        {:ok, _pid} ->
          :ok

        # Only reachable with `config :slink, :max_handler_tasks, N` set — the
        # opt-in backpressure valve. Shedding must be loud, never silent.
        {:error, :max_children} ->
          Logger.error(
            "Slink: handler task limit (:max_handler_tasks) reached; dropping a " <>
              "#{inspect(event.type)} event"
          )

        {:error, reason} ->
          Logger.error("Slink: could not start a handler task: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  Whether `event` needs a *synchronous* response folded into the transport's ACK.

  Only `view_submission` does: Slack expects a `response_action` (close, errors,
  update, push) in the immediate reply to control the modal. Everything else is
  acknowledged first and handled off-process.
  """
  def sync_ack?(%Event{kind: :interactive, type: :view_submission}), do: true
  def sync_ack?(_event), do: false

  @doc """
  Run `module`'s handler for a `sync_ack?/1` event and return the ACK payload map.

  The handler runs in an isolated, time-bounded task so a crash or a slow
  handler can't take down the transport (or blow Slack's ~3s window): it returns
  `%{}` — which closes the modal — on crash or timeout. A handler opts into a
  non-empty response by returning `{:ack, map}` (e.g.
  `{:ack, %{response_action: "errors", errors: %{...}}}`).
  """
  def ack_result(module, %Event{} = event, %Slink.Context{} = context) do
    emit_received(module, event, context)

    task =
      Task.Supervisor.async_nolink(task_supervisor(), fn -> run(module, event, context) end)

    case Task.yield(task, ack_timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, payload} when is_map(payload) -> encodable(payload)
      _ -> %{}
    end
  end

  # The payload is JSON-encoded into the transport's ACK frame. A handler that
  # returns a value JSON can't encode (a tuple, PID, …) must not crash the
  # transport — degrade to `%{}` (which closes the modal), like a crash does.
  defp encodable(payload) do
    _ = JSON.encode!(payload)
    payload
  rescue
    e ->
      Logger.error(
        "Slink: view_submission ack payload is not JSON-encodable (#{inspect(e)}); closing the modal"
      )

      %{}
  end

  defp emit_received(module, %Event{} = event, %Slink.Context{} = context) do
    :telemetry.execute(
      [:slink, :event, :received],
      %{system_time: System.system_time()},
      %{type: event.type, transport: context.transport, module: module}
    )
  end

  # Runs the user's handler and performs any reply it asks for. Called from
  # inside a task (see async/3), so there is no rescue here: OTP logs and
  # isolates a crashing handler.
  def dispatch(module, %Event{} = event, %Slink.Context{} = context) do
    context = %{context | event: event}
    invoke(module, event, context) |> perform_reply(context)
  end

  # Like dispatch/3 but returns the handler's `{:ack, map}` payload (else `%{}`)
  # for a transport to fold into its ACK, rather than performing a reply.
  defp run(module, %Event{} = event, %Slink.Context{} = context) do
    case invoke(module, event, %{context | event: event}) do
      {:ack, payload} when is_map(payload) ->
        payload

      other ->
        warn_dropped_reply(other, event.type)
        %{}
    end
  end

  # A modal submit can only answer via {:ack, map} (or :ok/anything to close it).
  # Returning {:reply, …} looks like it should send a message but is silently
  # dropped here — warn so the mistake is visible rather than a mysterious no-op.
  defp warn_dropped_reply({:reply, _}, type), do: log_dropped_reply(type)
  defp warn_dropped_reply({:reply, _, _}, type), do: log_dropped_reply(type)
  defp warn_dropped_reply(_other, _type), do: :ok

  defp log_dropped_reply(type) do
    Logger.warning(
      "Slink: a #{inspect(type)} handler returned {:reply, ...}, which is ignored — a modal " <>
        "submission answers only with {:ack, map} (or :ok to close). Nothing was sent."
    )
  end

  # Load the handler and call it. `function_exported?/3` reports false for a
  # module that hasn't been loaded yet, and the handler is typically referenced
  # only as a bare atom in config (`module: MyBot`), so nothing forces it to load
  # before the first event under lazy code loading — hence `ensure_loaded?`.
  defp invoke(module, %Event{} = event, context) do
    if Code.ensure_loaded?(module) and function_exported?(module, :handle_event, 2) do
      module.handle_event(event, context)
    else
      Logger.warning(
        "#{inspect(module)} does not implement handle_event/2; ignoring #{event.type}"
      )

      :ok
    end
  end

  # Keyed on {module, <delivery key>}, not the key alone: the same workspace
  # event delivered to two different Slack apps in one VM carries the same id,
  # and one bot's delivery must not swallow the other's.
  defp duplicate?(module, %Event{} = event) do
    case dedup_key(event) do
      nil -> false
      key -> Slink.Dedup.seen?({module, key})
    end
  end

  # Event callbacks dedup on Slack's event_id — stable across retries on either
  # transport, and authoritative (one absent means malformed; don't dedup).
  # Socket Mode slash-command/interactive envelopes carry no event_id, but a
  # redelivery (e.g. the same envelope re-sent on another connection of a fleet
  # after a dropped ACK) reuses the envelope_id, so those dedup on that.
  # Envelope ids are unique per delivery, so this can never swallow a distinct
  # event. (`view_submission` never reaches here — its sync-ack path must
  # answer every delivery, or the modal would hang.)
  defp dedup_key(%Event{} = event) do
    cond do
      is_binary(Event.event_id(event)) ->
        {:event, Event.event_id(event)}

      event.kind in [:slash_commands, :interactive] and is_binary(event.envelope_id) ->
        {:envelope, event.envelope_id}

      true ->
        nil
    end
  end

  defp ack_timeout, do: Application.get_env(:slink, :ack_timeout_ms, @default_ack_timeout_ms)

  # Test seam: lets tests point dispatch at a capped supervisor without
  # restarting the application (max_children is read at supervisor boot).
  defp task_supervisor,
    do: Application.get_env(:slink, :task_supervisor, Slink.TaskSupervisor)

  # Perform a reply if the handler asked for one via its return value; otherwise
  # do nothing. See `t:Slink.result/0`. Public (in this private module) so
  # `Slink.Testing.run/3` performs return-value replies the same way.
  def perform_reply({:reply, text}, context), do: Slink.reply(context, text)
  def perform_reply({:reply, text, opts}, context), do: Slink.reply(context, text, opts)
  def perform_reply(_other, _context), do: :ok
end
