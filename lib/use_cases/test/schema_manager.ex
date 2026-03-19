defmodule Test.SchemaManager do
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
        description: "Initial test harness schema",
        up: [
          "CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, document BLOB, room_id TEXT, last_modified_ms INTEGER, seqnum INTEGER, deleted_at INTEGER)",
          "CREATE INDEX IF NOT EXISTS idx_items_room_id ON items(room_id)"
        ],
        down: [
          "DROP TABLE IF EXISTS items"
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
