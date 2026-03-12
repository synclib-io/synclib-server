defmodule MMO.SchemaManager do
  @moduledoc """
  MMO schema manager — manages client SQLite schema versions.

  Provides migrations that clients apply to their local SQLite database
  to match the server's Postgres schema.
  """

  @behaviour SyncServer.SchemaManagerBehaviour

  @current_version 1

  @impl true
  def current_version, do: @current_version

  @impl true
  def check_client_version(client_version) when client_version == @current_version do
    {:ok, :up_to_date}
  end

  def check_client_version(client_version) when client_version < @current_version do
    {:ok, migrations} = get_migrations_from(client_version + 1)
    {:ok, :upgrade_needed, migrations}
  end

  def check_client_version(_client_version) do
    {:error, :client_too_new}
  end

  @impl true
  def get_migrations_from(from_version) do
    migrations = all_migrations()
    filtered = Enum.filter(migrations, fn m -> m.version >= from_version end)
    {:ok, filtered}
  end

  @impl true
  def all_migrations do
    [
      %{
        version: 1,
        description: "Initial MMO schema",
        up: [
          # Users
          "CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, name TEXT, email TEXT, document BLOB, online INTEGER DEFAULT 0, last_modified_ms INTEGER, seqnum INTEGER, deleted_at INTEGER)",
          "CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)",

          # Tasks
          "CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, user_id TEXT, title TEXT, description TEXT, status TEXT DEFAULT 'pending', document BLOB, last_modified_ms INTEGER, seqnum INTEGER, deleted_at INTEGER)",
          "CREATE INDEX IF NOT EXISTS idx_tasks_user_id ON tasks(user_id)",
          "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)",

          # Guild chat
          "CREATE TABLE IF NOT EXISTS guild_chat (id TEXT PRIMARY KEY, guild_id TEXT, user_id TEXT, message TEXT, document BLOB, last_modified_ms INTEGER, seqnum INTEGER, deleted_at INTEGER)",
          "CREATE INDEX IF NOT EXISTS idx_guild_chat_guild_id ON guild_chat(guild_id)",

          # Player positions
          "CREATE TABLE IF NOT EXISTS player_positions (id TEXT PRIMARY KEY, user_id TEXT, zone_id TEXT, x REAL DEFAULT 0, y REAL DEFAULT 0, z REAL DEFAULT 0, document BLOB, last_modified_ms INTEGER, seqnum INTEGER, deleted_at INTEGER)",
          "CREATE INDEX IF NOT EXISTS idx_player_positions_zone_id ON player_positions(zone_id)",
          "CREATE INDEX IF NOT EXISTS idx_player_positions_user_id ON player_positions(user_id)",

          # World events
          "CREATE TABLE IF NOT EXISTS world_events (id TEXT PRIMARY KEY, event_type TEXT, title TEXT, description TEXT, document BLOB, last_modified_ms INTEGER, seqnum INTEGER, deleted_at INTEGER)",
          "CREATE INDEX IF NOT EXISTS idx_world_events_type ON world_events(event_type)"
        ],
        down: [
          "DROP TABLE IF EXISTS world_events",
          "DROP TABLE IF EXISTS player_positions",
          "DROP TABLE IF EXISTS guild_chat",
          "DROP TABLE IF EXISTS tasks",
          "DROP TABLE IF EXISTS users"
        ]
      }
    ]
  end

  @impl true
  def to_client_format(migrations) do
    Enum.map(migrations, fn m ->
      %{
        "version" => m.version,
        "description" => m.description,
        "sql" => m.up
      }
    end)
  end
end
