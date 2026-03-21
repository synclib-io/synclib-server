# SyncLib Server

Real-time bidirectional data sync server built on Phoenix channels and PostgreSQL.

Clients maintain a local SQLite database that stays in sync with the server's Postgres. The sync system provides:

- **Seqnum-based incremental sync** — Global monotonic sequence numbers on every row. Clients track their last-seen seqnum per table and pull only newer rows.
- **Merkle tree verification** — SHA256-based integrity checking. Clients compare merkle roots, drill into differing blocks, and repair discrepancies.
- **Scoped broadcasting** — Changes broadcast to the correct channel (user, guild, zone, world, party) so clients only receive relevant updates.
- **Client schema management** — Server pushes SQLite DDL migrations to clients so their local database stays in sync with schema changes.

## Architecture

```
Client (SQLite)                    Server (Postgres)
┌─────────────┐                   ┌──────────────────┐
│ Local DB    │ ◄── WebSocket ──► │ Phoenix Channel  │
│ (SQLite)    │     (sync proto)  │                  │
│             │                   │ ┌──────────────┐ │
│ local writes│ ──── push ─────►  │ │ Seqnum       │ │
│             │                   │ │ Triggers     │ │
│ seqnum track│ ◄─── pull ──────  │ │              │ │
│             │                   │ │ row_hash     │ │
│ merkle tree │ ◄── verify ────►  │ │ Triggers     │ │
└─────────────┘                   │ └──────────────┘ │
                                  │                  │
                                  │ ┌──────────────┐ │
                                  │ │ Broadcaster  │ │
                                  │ │ (PubSub)     │ │
                                  │ └──────────────┘ │
                                  └──────────────────┘
```

### Sync Flow (Unified Sync)

1. **Client joins** a channel (e.g., `sync:user:abc123`)
2. **Schema check** — server sends migrations if client schema is outdated
3. **Push** — client pushes local changes, server applies and broadcasts to others
4. **Pull** — client sends `table_seqnums`, server streams only newer rows
5. **Merkle verify** — integrity check compares hashes, repairs mismatches

## Getting Started

### Prerequisites

- Elixir 1.14+
- PostgreSQL 14+
- (Optional) `pg_synclib_hash` Postgres extension for fast merkle verification

### Setup

```bash
# Install dependencies
mix deps.get

# Create and migrate the database
mix ecto.setup
```

### Run

```bash
# Migrate and start (use this every time)
mix ecto.migrate && mix phx.server
```

The server starts on `http://localhost:4444` by default.

Migrations are idempotent — `mix ecto.migrate` skips already-run ones. Per-table triggers (seqnum + row_hash) are attached automatically at startup by `SetupTriggers`.

### Connect

Connect a WebSocket to `/socket` with params:

```json
{
  "token": "<JWT token>",
  "client_id": "my-client"
}
```

Set `JWT_SECRET` env var for HS256 token verification.

Then join a channel:

```json
// Join user channel
{"topic": "sync:user:user-123", "event": "phx_join", "payload": {"client_id": "my-client"}}
```

## Migrations

`priv/repo/migrations/` contains only core sync infrastructure:

```
priv/repo/migrations/
├── 20260310000000_setup_sync_infrastructure.exs   # Seqnum sequence, trigger function, pg_synclib_hash, row_hash columns
└── 20260319000000_create_test_tables.exs          # Test suite tables
```

Use-case table migrations go here too, but the core migration must run first (it creates the seqnum function that triggers depend on). See [docs/example_migration_mmo.exs](docs/example_migration_mmo.exs) for an example of a use-case migration that creates synced tables with the required columns (`id`, `seqnum`, `deleted_at`).

## Project Structure

```
lib/
├── sync_server/                  # Core sync infrastructure
│   ├── application.ex            # OTP supervisor
│   ├── repo.ex                   # Ecto repo
│   ├── setup_triggers.ex         # Auto-creates seqnum + row_hash triggers
│   ├── merkle.ex                 # Merkle tree computation
│   ├── hash.ex                   # WASM-based cross-platform hashing
│   ├── schema_introspection.ex   # Postgres → SQLite DDL conversion
│   ├── broadcaster.ex            # Channel broadcasting helpers
│   ├── auth/jwt_verifier.ex      # JWT verification (HS256 + RS256)
│   │
│   │   # Behaviours (implement these for your use case)
│   ├── channel_handler.ex        # Channel join → socket assigns
│   ├── snapshot_queries.ex       # Table + assigns → Ecto query
│   ├── change_handler.ex         # Authorization + CRUD for writes
│   ├── broadcast_router.ex       # Route changes to channel topics
│   ├── connection_handler.ex     # Connect/disconnect hooks
│   └── schema_manager_behaviour.ex  # Client schema versioning
│
├── sync_server_web/              # Phoenix web layer
│   ├── endpoint.ex
│   ├── router.ex
│   ├── user_socket.ex
│   ├── channels/
│   │   ├── sync_channel.ex       # Core sync protocol
│   │   └── row_sanitizer.ex      # Default row sanitizer (pass-through)
│   ├── controllers/
│   │   └── health_controller.ex
│   └── plugs/
│       └── cors.ex
│
└── use_cases/mmo/                # MMO demo (example use case)
    ├── channel.ex                # Channel join logic
    ├── broadcast_router.ex       # Route changes by table/zone/guild
    ├── snapshot_queries.ex       # Scoped queries per channel type
    ├── change_handler.ex         # CRUD for MMO tables
    ├── connection_handler.ex     # Connect/disconnect logging
    ├── schema_manager.ex         # Client schema v1
    └── schema/                   # Ecto schemas
        ├── user.ex
        ├── task.ex
        ├── guild_chat.ex
        ├── player_position.ex
        └── world_event.ex
```

## Adding Your Own Use Case

See [docs/adding-a-use-case.md](docs/adding-a-use-case.md) for a step-by-step guide.

The short version:
1. Implement the 6 behaviours (`ChannelHandler`, `SnapshotQueries`, `ChangeHandler`, `BroadcastRouter`, `ConnectionHandler`, `SchemaManagerBehaviour`)
2. Create Ecto schemas for your tables
3. Create a migration
4. Update `config/config.exs` to point to your modules

## Documentation

- [Architecture](docs/architecture.md) — Detailed explanation of seqnum, merkle, and channel scoping
- [Sync Protocol](docs/sync-protocol.md) — Channel message reference
- [Adding a Use Case](docs/adding-a-use-case.md) — Step-by-step guide

## Schema Migrations

The server is the single source of truth for database schema. Clients receive SQLite DDL migrations over the sync channel and apply them locally.

### How it works

1. **Client connects** and sends its current `schema_version` (an integer) in the `hello` message
2. **Server compares** the client's version to the current version
3. If the client is behind, the server responds with `status: "upgrade_needed"` and an array of migrations to apply
4. **Client applies** each migration's SQL statements sequentially to its local SQLite database
5. Client updates its local `schema_version` in the `_metadata` table

### Migration format

Each migration is a versioned object with an array of SQL statements:

```json
{
  "version": 3,
  "description": "Add tags column to todos",
  "sql": [
    "ALTER TABLE todos ADD COLUMN tags TEXT"
  ]
}
```

### Implementing the SchemaManager behaviour

Your use case module implements `SchemaManagerBehaviour`:

```elixir
defmodule MyApp.SchemaManager do
  @behaviour SyncServer.SchemaManagerBehaviour

  @current_version 3

  @migrations [
    %{version: 1, description: "Initial schema", sql: [
      "CREATE TABLE IF NOT EXISTS todos (id TEXT PRIMARY KEY, document BLOB, title TEXT, completed INTEGER)"
    ]},
    %{version: 2, description: "Add due_date", sql: [
      "ALTER TABLE todos ADD COLUMN due_date TEXT"
    ]},
    %{version: 3, description: "Add tags", sql: [
      "ALTER TABLE todos ADD COLUMN tags TEXT"
    ]}
  ]

  @impl true
  def current_version, do: @current_version

  @impl true
  def get_migrations_from(version) do
    @migrations
    |> Enum.filter(& &1.version > version)
    |> Enum.sort_by(& &1.version)
  end
end
```

### Schema introspection

For version 1, you can use `SyncServer.SchemaIntrospection.generate_full_schema()` to automatically generate SQLite DDL from your Postgres tables instead of writing it by hand. It handles type mapping (JSONB → BLOB, timestamp → INTEGER, boolean → INTEGER, etc.).

### Guidelines

- **Never modify a deployed migration** — create a new version instead
- **Use idempotent DDL** — `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`
- **Deploy server first** — old clients continue working since the server supports version ranges
- **Migrations are additive** — clients always apply in order, never skip versions

## pg_synclib_hash Extension

The `pg_synclib_hash` Postgres extension provides a trigger function that computes row hashes in Postgres, making merkle verification much faster. Without it, the server falls back to WASM-based hash computation.

To run without the extension, set in config:

```elixir
config :sync_server, setup_row_hash_triggers: false
```

## License

MIT
