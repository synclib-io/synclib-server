defmodule SyncServer.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      SyncServer.Repo,
      {Phoenix.PubSub, name: SyncServer.PubSub},
      SyncServer.Hash,
      SyncServerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SyncServer.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Set up sync triggers after Repo is running (idempotent)
    case result do
      {:ok, _pid} -> setup_triggers()
      _ -> :ok
    end

    result
  end

  defp setup_triggers do
    Task.start(fn ->
      try do
        SyncServer.SetupTriggers.run()
      rescue
        e -> Logger.warning("[Application] Trigger setup failed: #{Exception.message(e)}")
      end
    end)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SyncServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
