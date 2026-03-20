# Architecture

## Overview

SyncLib Server provides real-time bidirectional sync between a PostgreSQL server and SQLite clients over Phoenix channels. The architecture has two key mechanisms: **seqnum-based incremental sync** and **merkle tree verification**.

## Seqnum (Sequence Number) Mechanism

Every synced table has a `seqnum` column. A global PostgreSQL sequence (`global_seqnum_seq`) provides monotonically increasing numbers. A BEFORE INSERT OR UPDATE trigger automatically assigns the next seqnum to every row change.

```sql
-- Trigger function (created automatically by SetupTriggers)
CREATE FUNCTION update_seqnum_on_change() RETURNS TRIGGER AS $$
BEGIN
  NEW.seqnum = nextval('global_seqnum_seq');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### How Incremental Sync Works

1. Client tracks `max_seqnum` per table locally
2. On sync, client sends `table_seqnums: {"users": 42, "tasks": 37}`
3. Server queries `WHERE seqnum > 42` for users, `WHERE seqnum > 37` for tasks
4. Only changed rows are returned
5. Client updates its local seqnum tracking

This is efficient because seqnums are global — a single number tells you everything that changed across all tables since you last synced.

## Merkle Tree Verification

For data integrity, clients periodically build a merkle tree from their locally stored `row_hash` values and compare it with the server.

### Server-Authoritative row_hash

The PostgreSQL trigger (`pg_synclib_hash`) computes `row_hash` at write time. This server-computed hash is the single source of truth. Clients receive `row_hash` values via:
- Sync data batches (snapshot and incremental)
- ACK responses (after pushing a change)
- Broadcast messages (changes from other clients)
- Merkle repair responses (fetch_blocks, lww_blocks)

Clients store these values locally and use them for merkle comparison — they never compute `row_hash` themselves during normal sync. The `synclib_hash` C library / WASM module is preserved for optional client-side data integrity checks (e.g., detecting local corruption), but is not required for sync.

### Hash Format

- **Row hash**: `SHA256(row_id + "|" + sorted_json(row_data))` → 64-char lowercase hex
- **Block hash**: `SHA256(row_hash_1 + row_hash_2 + ... + row_hash_n)` → 64-char hex
- **Merkle root**: Binary tree of block hashes, odd nodes passed up as-is

### Verification Flow

```
Client                              Server
  │                                    │
  │  Build merkle tree from stored     │
  │  row_hash values (no local         │
  │  computation needed)               │
  │                                    │
  ├─── merkle_verify ────────────────►│  Compare root hashes per table
  │    {table_hashes: {...}}           │
  │                                    │
  │◄── mismatches_found ─────────────┤  Return mismatched tables
  │                                    │
  ├─── merkle_block_hashes ──────────►│  Compare block-level hashes
  │    {table, block_hashes: [...]}    │
  │                                    │
  │◄── differing_blocks ──────────────┤  Return which blocks differ
  │                                    │
  ├─── merkle_fetch_blocks ──────────►│  Get server's rows for bad blocks
  │    {table, blocks: [3, 7]}         │  (rows include row_hash)
  │                                    │
  │◄── block rows ────────────────────┤  Client stores rows + row_hash
  │                                    │
```

### Server Hash Computation

When `pg_synclib_hash` is installed, each row gets a precomputed `row_hash` column (set by Postgres BEFORE trigger). The server reads these directly for merkle comparison — no WASM computation needed. Without the extension, the server loads full rows and computes hashes via WASM (slower but functional).

## Channel Scoping

Data is partitioned across channel topics:

| Channel | Topic Format | Data Scope |
|---------|-------------|------------|
| User | `sync:user:{user_id}` | User's private data (profile, tasks) |
| Guild | `sync:guild:{guild_id}` | Guild-specific data (chat, members) |
| Zone | `sync:zone:{zone_id}` | Location-based data (player positions) |
| World | `sync:world` | Global announcements, world events |
| Party | `sync:party:{party_id}` | Small group data |

The `SnapshotQueries` behaviour defines which rows belong to which channel. The `BroadcastRouter` behaviour defines where changes get broadcast.

## Pluggable Architecture

The sync infrastructure is generic. Use-case specific logic is injected via 6 behaviours configured at compile time:

```elixir
# config/config.exs
config :sync_server,
  channel_handler: MyApp.Channel,
  snapshot_queries: MyApp.SnapshotQueries,
  change_handler: MyApp.ChangeHandler,
  broadcast_router: MyApp.BroadcastRouter,
  connection_handler: MyApp.ConnectionHandler,
  schema_manager: MyApp.SchemaManager
```

The `SyncChannel` reads these at compile time via `Application.compile_env/3` and delegates to them at runtime.

## Synced Table Requirements

For a table to participate in sync, it needs:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | `TEXT` (PK) | Unique row identifier |
| `seqnum` | `BIGINT` | Auto-assigned by trigger |
| `deleted_at` | `TIMESTAMP` | Soft delete (NULL = active) |
| `last_modified_ms` | `BIGINT` | Client-assigned modification time |
| `document` | `JSONB` | Optional flexible data field |
| `row_hash` | `TEXT` | Server-authoritative hash, set by pg_synclib_hash trigger. Clients store this value — never compute it locally for sync. |

`SetupTriggers` auto-discovers tables that have both `id` and `deleted_at` columns and creates the seqnum trigger for them.
