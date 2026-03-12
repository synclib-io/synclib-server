# Adding a Use Case

This guide walks through adding your own application on top of the sync infrastructure. The MMO demo (`lib/use_cases/mmo/`) is a complete working example.

## Step 1: Define Your Tables

Create Ecto schemas for each synced table. Every synced table needs at minimum:

```elixir
defmodule MyApp.Schema.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "items" do
    field :name, :string
    field :owner_id, :string
    field :document, :map          # Flexible JSONB field
    field :last_modified_ms, :integer
    field :seqnum, :integer        # Auto-assigned by Postgres trigger
    field :deleted_at, :utc_datetime  # Soft delete
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:id, :name, :owner_id, :document, :last_modified_ms, :deleted_at])
    |> validate_required([:id])
  end
end
```

## Step 2: Create a Migration

```elixir
# priv/repo/migrations/20260101000000_create_items.exs
defmodule SyncServer.Repo.Migrations.CreateItems do
  use Ecto.Migration

  def change do
    create table(:items, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string
      add :owner_id, :string
      add :document, :map
      add :last_modified_ms, :bigint
      add :seqnum, :bigint
      add :deleted_at, :utc_datetime
    end

    create index(:items, [:owner_id])
  end
end
```

## Step 3: Implement the Behaviours

### ChannelHandler

Defines how channel topics map to socket assigns:

```elixir
defmodule MyApp.Channel do
  @behaviour SyncServer.ChannelHandler

  @impl true
  def join("sync:user:" <> user_id, %{"client_id" => client_id} = _params) do
    %{client_id: client_id, user_id: user_id, channel_type: :user}
  end

  def join(_channel, _params), do: {:error, "unknown channel"}

  @impl true
  def tables_for_channel(%{channel_type: :user}), do: ["items"]
  def tables_for_channel(_), do: []
end
```

### SnapshotQueries

Defines what data each channel type can see:

```elixir
defmodule MyApp.SnapshotQueries do
  @behaviour SyncServer.SnapshotQueries
  import Ecto.Query

  @impl true
  def build_query("items", %{channel_type: :user, user_id: user_id} = assigns) do
    query = from(i in MyApp.Schema.Item, where: i.owner_id == ^user_id)
    maybe_filter_seqnum(query, assigns)
  end

  def build_query(_table, _assigns) do
    from(i in MyApp.Schema.Item, where: false)
  end

  defp maybe_filter_seqnum(query, %{since_seqnum: s}) when is_integer(s) and s > 0 do
    from(q in query, where: q.seqnum > ^s)
  end
  defp maybe_filter_seqnum(query, _), do: query
end
```

### ChangeHandler

Handles writes from clients:

```elixir
defmodule MyApp.ChangeHandler do
  @behaviour SyncServer.ChangeHandler
  alias SyncServer.Repo

  @impl true
  def apply_change("items", "insert", row_id, data, _assigns) do
    %MyApp.Schema.Item{}
    |> MyApp.Schema.Item.changeset(Map.put(data, "id", row_id))
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :id)
  end

  def apply_change("items", "update", row_id, data, _assigns) do
    case Repo.get(MyApp.Schema.Item, row_id) do
      nil -> apply_change("items", "insert", row_id, data, %{})
      record -> record |> MyApp.Schema.Item.changeset(data) |> Repo.update()
    end
  end

  def apply_change("items", "delete", row_id, _data, _assigns) do
    case Repo.get(MyApp.Schema.Item, row_id) do
      nil -> {:ok, nil}
      record -> record |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()
    end
  end

  @impl true
  def get_schema_for_table("items"), do: MyApp.Schema.Item
end
```

### BroadcastRouter

Routes changes to the right channels:

```elixir
defmodule MyApp.BroadcastRouter do
  @behaviour SyncServer.BroadcastRouter

  @impl true
  def determine_topic("items", data, _socket) do
    "sync:user:#{data["owner_id"]}"
  end

  def determine_topic(_table, _data, socket), do: socket.topic

  @impl true
  def broadcast_change(socket, table, operation, row_id, data) do
    topic = determine_topic(table, data, socket)
    message = %{
      "table" => table, "operation" => operation,
      "row_id" => row_id, "data" => data,
      "timestamp" => System.system_time(:millisecond), "source" => "client"
    }
    SyncServerWeb.Endpoint.broadcast_from(socket.channel_pid, topic, "change", message)
    :ok
  end
end
```

### ConnectionHandler

```elixir
defmodule MyApp.ConnectionHandler do
  @behaviour SyncServer.ConnectionHandler
  require Logger

  @impl true
  def handle_connect(socket) do
    Logger.info("User #{socket.assigns[:user_id]} connected")
    :ok
  end

  @impl true
  def handle_disconnect(_reason, socket) do
    Logger.info("User #{socket.assigns[:user_id]} disconnected")
    :ok
  end
end
```

### SchemaManager

Manages client SQLite schema versions:

```elixir
defmodule MyApp.SchemaManager do
  @behaviour SyncServer.SchemaManagerBehaviour

  @current_version 1

  @impl true
  def current_version, do: @current_version

  @impl true
  def check_client_version(v) when v == @current_version, do: {:ok, :up_to_date}
  def check_client_version(v) when v < @current_version do
    {:ok, migs} = get_migrations_from(v + 1)
    {:ok, :upgrade_needed, migs}
  end
  def check_client_version(_), do: {:error, :client_too_new}

  @impl true
  def get_migrations_from(from) do
    {:ok, Enum.filter(all_migrations(), fn m -> m.version >= from end)}
  end

  @impl true
  def all_migrations do
    [
      %{
        version: 1,
        description: "Initial schema",
        up: [
          "CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, name TEXT, owner_id TEXT, document BLOB, last_modified_ms INTEGER, seqnum INTEGER, deleted_at INTEGER)",
          "CREATE INDEX IF NOT EXISTS idx_items_owner ON items(owner_id)"
        ],
        down: ["DROP TABLE IF EXISTS items"]
      }
    ]
  end

  @impl true
  def to_client_format(migrations) do
    Enum.map(migrations, fn m -> %{"version" => m.version, "description" => m.description, "sql" => m.up} end)
  end
end
```

## Step 4: Update Config

```elixir
# config/config.exs
config :sync_server,
  snapshot_queries: MyApp.SnapshotQueries,
  channel_handler: MyApp.Channel,
  change_handler: MyApp.ChangeHandler,
  broadcast_router: MyApp.BroadcastRouter,
  connection_handler: MyApp.ConnectionHandler,
  schema_manager: MyApp.SchemaManager
```

## Step 5: Run

```bash
mix ecto.migrate
mix phx.server
```

`SetupTriggers` will auto-discover your new tables (they have `id` + `deleted_at`) and create seqnum triggers for them.
