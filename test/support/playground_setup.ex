defmodule Slink.Test.PlaygroundSetup do
  @moduledoc false
  # Shared boot/teardown for tests that start a real playground: lift the
  # suite-wide :identity_fetch stub so auth.test resolves through the fake
  # API, and put the global env back afterwards. Returns the base URL.
  import ExUnit.Callbacks

  def start!(name) do
    stub = Application.get_env(:slink, :identity_fetch)
    Application.delete_env(:slink, :identity_fetch)

    start_supervised!(
      {Slink.Playground, module: Slink.Test.PlaygroundTestBot, port: 0, name: name}
    )

    on_exit(fn ->
      Application.put_env(:slink, :identity_fetch, stub)
      # The workspace restores :api_base_url on clean shutdown; clear any
      # leftover from an abnormal exit so later suites can't hit a dead port.
      Application.delete_env(:slink, :api_base_url)
    end)

    Slink.Playground.url(name)
  end
end
