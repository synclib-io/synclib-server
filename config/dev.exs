import Config

config :sync_server, SyncServer.Repo,
  username: "phil",
  password: "postgres",
  hostname: "localhost",
  database: "synclib_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  queue_target: 50

config :sync_server, SyncServerWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4444],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "SECRET_KEY_BASE_CHANGE_IN_PRODUCTION",
  watchers: []

config :logger, :console, format: "[$level] $message\n"
config :logger, level: :debug

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
