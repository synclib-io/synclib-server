defmodule SyncServer.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias SyncServer.Repo
      import Ecto.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SyncServer.Repo, shared: !tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Install triggers in each test's sandbox transaction
    SyncServer.SetupTriggers.run()

    :ok
  end
end
