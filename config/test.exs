import Config

config :sync_server, SyncServer.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "synclib_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :sync_server, SyncServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_purposes_only",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
