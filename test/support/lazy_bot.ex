defmodule Slink.Test.LazyBot do
  @moduledoc """
  A trivial bot used only by `Slink.DispatcherTest` to exercise the
  lazy-code-loading path: the dispatcher must load the handler module before
  checking for `handle_event/2`, since the module is typically only referenced
  as a bare atom in config and nothing forces it to load before the first event.

  It lives in `test/support` (compiled to the code path) so the test can purge
  it from memory and rely on the dispatcher reloading it from disk. Nothing else
  references it, so purging it can't race with other async tests.
  """

  use Slink

  @impl true
  def handle_event(event, _context) do
    send(:dispatcher_sink, {:lazy_handled, event.type})
    :ok
  end
end
