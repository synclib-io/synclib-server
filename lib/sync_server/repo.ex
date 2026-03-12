defmodule SyncServer.Repo do
  use Ecto.Repo,
    otp_app: :sync_server,
    adapter: Ecto.Adapters.Postgres
end
