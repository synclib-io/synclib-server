# Sync Protocol Reference

All communication happens over Phoenix channels via WebSocket at `/socket`.

## Connection

Connect with params:
```json
{"token": "<JWT>", "client_id": "my-client"}
```

## Channel Topics

| Topic | Description |
|-------|-------------|
| `sync:user:{user_id}` | User-specific data |
| `sync:guild:{guild_id}` | Guild/team data |
| `sync:zone:{zone_id}` | Location-based data |
| `sync:world` | Global data |
| `sync:party:{party_id}` | Small group data |

## Messages

### `hello` (client → server)

Client announces presence and schema version.

**Request:**
```json
{
  "client_id": "abc",
  "last_seqnum": 42,
  "schema_version": 1
}
```

**Response:**
```json
{
  "status": "ok",
  "message": "Schema up to date",
  "merkle_block_size": 100
}
```

Or if upgrade needed:
```json
{
  "status": "upgrade_needed",
  "current_version": 2,
  "migrations": [{"version": 2, "description": "...", "sql": ["CREATE TABLE..."]}]
}
```

### `stream_snapshot` (client → server)

Request initial data for tables. Data is streamed in batches.

**Request:**
```json
{
  "tables": ["users", "tasks"],
  "table_seqnums": {"users": 10, "tasks": 5}
}
```

**Response:** `{stream_id: "..."}`

**Server pushes:** Multiple `snapshot_batch` events, then `snapshot_complete`.

```json
// snapshot_batch
{"stream_id": "abc", "table": "users", "rows": [{...}, {...}]}

// snapshot_complete
{"stream_id": "abc", "channel_id": "sync:user:123"}
```

### `request_changes` (client → server)

Pull incremental changes since a seqnum.

**Request:**
```json
{
  "since_seqnum": 42,
  "table": "users",
  "limit": 100
}
```

**Response:**
```json
{
  "type": "changes_batch",
  "changes": [{"table": "users", "row": {...}, "seqnum": 43}],
  "from_seqnum": 42,
  "to_seqnum": 43,
  "has_more": false
}
```

### `change` (client → server)

Push a single change.

**Request:**
```json
{
  "table": "tasks",
  "operation": "insert",
  "row_id": "task-1",
  "seqnum": 1,
  "data": {"title": "Buy sword", "user_id": "user-123"}
}
```

**Server pushes:** `ack` event
```json
{"seqnum": 1, "success": true, "server_seqnum": 44}
```

Server also broadcasts `change` to other clients on the appropriate topic.

### `sync` (client → server)

Unified bidirectional sync — push + pull + schema in one round-trip.

**Request:**
```json
{
  "client_id": "abc",
  "schema_version": 1,
  "table_seqnums": {"users": 10, "tasks": 5},
  "tables": ["users", "tasks"],
  "pending_changes": [
    {"table": "tasks", "operation": "insert", "row_id": "t1", "local_seqnum": 1, "data": {...}}
  ],
  "stripped_rows": [],
  "force_refresh_tables": []
}
```

**Response:** `{stream_id: "..."}`

**Server pushes:**
1. `sync_acks` — Acknowledgments for pending_changes
2. `sync_batch` — Data batches per table
3. `sync_complete` — Final seqnums and stats

### `merkle_verify` (client → server)

Compare merkle root hashes.

**Request:**
```json
{
  "table_hashes": {
    "users": {"root_hash": "abc123...", "block_count": 3, "row_count": 250},
    "tasks": "def456..."
  },
  "block_size": 100
}
```

**Response:**
```json
{
  "status": "mismatches_found",
  "mismatches": [{
    "table": "users",
    "client_hash": "abc123...",
    "server_root_hash": "xyz789...",
    "server_row_count": 251,
    "server_block_count": 3,
    "jsonb_columns": ["document"],
    "row_ids": ["user-1", "user-2", ...]
  }]
}
```

### `merkle_block_hashes` (client → server)

Drill into block-level hashes for a mismatched table.

**Request:**
```json
{
  "table": "users",
  "block_hashes": ["aaa...", "bbb...", "ccc..."],
  "block_size": 100
}
```

**Response:**
```json
{
  "table": "users",
  "differing_blocks": [1],
  "server_block_count": 3
}
```

### `merkle_fetch_blocks` (client → server)

Fetch server's rows for specific blocks to repair client.

**Request:**
```json
{
  "table": "users",
  "blocks": [1],
  "block_size": 100
}
```

**Response:**
```json
{
  "table": "users",
  "block": 1,
  "rows": [{...}, {...}],
  "row_ids": ["user-101", "user-102", ...]
}
```

### `merkle_push_blocks` (client → server)

Push client's rows to repair server.

**Request:**
```json
{
  "table": "users",
  "block_index": 1,
  "block_size": 100,
  "rows": [{...}],
  "client_row_ids": ["user-101", "user-102"]
}
```

**Response:**
```json
{
  "table": "users",
  "block_index": 1,
  "applied": 5,
  "rejected": 0,
  "deleted": 1,
  "errors": []
}
```

### `merkle_lww_blocks` (client → server)

Last-write-wins conflict resolution. Client sends its rows with timestamps, server compares and resolves.

**Request:**
```json
{
  "table": "users",
  "block_index": 1,
  "block_size": 100,
  "rows": [{...}],
  "client_row_ids": ["user-101"]
}
```

**Response:**
```json
{
  "table": "users",
  "block_index": 1,
  "client_wins": ["user-101"],
  "server_wins": [{...}],
  "applied_from_client": 1,
  "sent_to_client": 2
}
```

### `fetch_row` (client → server)

Fetch a single complete row.

**Request:**
```json
{"table": "users", "row_id": "user-123"}
```

**Response:**
```json
{"row": {"id": "user-123", "name": "Alice", ...}}
```

### `schema_check` (client → server)

Check if a schema update is needed.

**Request:** `{"version": 1}`

**Response:** `{"status": "up_to_date", "current_version": 1}`
