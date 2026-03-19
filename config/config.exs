import Config

use_case = System.get_env("USE_CASE", "test")

case use_case do
  "mmo" ->
    config :sync_server,
      ecto_repos: [SyncServer.Repo],
      generators: [timestamp_type: :utc_datetime],
      snapshot_queries: MMO.SnapshotQueries,
      channel_handler: MMO.Channel,
      change_handler: MMO.ChangeHandler,
      broadcast_router: MMO.BroadcastRouter,
      connection_handler: MMO.ConnectionHandler,
      custom_queries: nil,
      schema_manager: MMO.SchemaManager,
      hash_columns: []

  _ ->
    config :sync_server,
      ecto_repos: [SyncServer.Repo],
      generators: [timestamp_type: :utc_datetime],
      snapshot_queries: Test.SnapshotQueries,
      channel_handler: Test.Channel,
      change_handler: Test.ChangeHandler,
      broadcast_router: Test.BroadcastRouter,
      connection_handler: Test.ConnectionHandler,
      custom_queries: nil,
      schema_manager: Test.SchemaManager,
      hash_columns: ["last_modified_ms"]
end

config :sync_server, SyncServerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: SyncServerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SyncServer.PubSub,
  live_view: [signing_salt: "secret"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
