defmodule SyncServerWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      alias SyncServer.Repo
      @endpoint SyncServerWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SyncServer.Repo, shared: !tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    SyncServer.SetupTriggers.run()

    :ok
  end
end
