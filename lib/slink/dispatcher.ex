defmodule Slink.Dispatcher do
  @moduledoc false
  require Logger

  @doc """
  Dispatch `event` to `module` off-process, under `Slink.TaskSupervisor`.

  This is the single path both transports use after they've acknowledged the
  event to Slack. Crash containment is the task's job — a handler that raises
  kills only its own (temporary) task; the transport keeps running.
  """
  @spec async(module(), Slink.Event.t(), Slink.Context.t()) :: :ok
  def async(module, %Slink.Event{} = event, %Slink.Context{} = context) do
    :telemetry.execute(
      [:slink, :event, :received],
      %{system_time: System.system_time()},
      %{type: event.type, transport: context.transport, module: module}
    )

    Task.Supervisor.start_child(Slink.TaskSupervisor, fn ->
      dispatch(module, event, context)
    end)

    :ok
  end

  # Runs the user's handler. Called from inside a task (see async/3), so there is
  # no rescue here: OTP logs and isolates a crashing handler.
  @spec dispatch(module(), Slink.Event.t(), Slink.Context.t()) :: :ok
  def dispatch(module, %Slink.Event{} = event, %Slink.Context{} = context) do
    if function_exported?(module, :handle_event, 2) do
      _ = module.handle_event(event, context)
      :ok
    else
      Logger.warning(
        "#{inspect(module)} does not implement handle_event/2; ignoring #{event.type}"
      )

      :ok
    end
  end
end
