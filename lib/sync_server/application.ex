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

    # Attach per-table triggers after Repo is up (idempotent)
    case result do
      {:ok, _pid} ->
        SyncServer.SetupTriggers.run()
      _ -> :ok
    end

    result
  end

  @impl true
  def config_change(changed, _new, removed) do
    SyncServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
