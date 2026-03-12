import Config

# MMO demo use case — configure your own behaviours here
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
