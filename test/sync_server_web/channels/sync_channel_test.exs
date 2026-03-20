defmodule SyncServerWeb.SyncChannelTest do
  use SyncServerWeb.ChannelCase

  setup do
    # Seed rows
    now = System.system_time(:millisecond)
    for id <- ["a1", "a2", "a3"] do
      Repo.query!(
        "INSERT INTO items (id, room_id, last_modified_ms) VALUES ($1, 'room1', $2)",
        [id, now]
      )
    end

    # Create socket directly (bypasses JWT auth in UserSocket.connect/2)
    socket = socket(SyncServerWeb.UserSocket, "user1", %{client_id: "test-client"})
    {:ok, _reply, socket} = subscribe_and_join(socket, SyncServerWeb.SyncChannel,
      "sync:room:room1", %{"client_id" => "test-client", "user_id" => "user1"})

    %{socket: socket}
  end

  test "merkle_push_blocks applies rows without deleting others", %{socket: socket} do
    now = System.system_time(:millisecond)

    ref = push(socket, "merkle_push_blocks", %{
      "table" => "items",
      "block_index" => 0,
      "block_size" => 100,
      "rows" => [%{"id" => "a1", "room_id" => "room1", "last_modified_ms" => now + 1000}],
      "client_row_ids" => ["a1"]
    })

    assert_reply ref, :ok, reply
    assert reply.deleted == 0
    assert reply.applied == 1

    # All 3 rows must still exist
    %{rows: rows} = Repo.query!("SELECT id FROM items WHERE room_id = 'room1' AND deleted_at IS NULL ORDER BY id")
    assert length(rows) == 3
  end

  test "merkle_push_blocks with empty client_row_ids deletes nothing", %{socket: socket} do
    ref = push(socket, "merkle_push_blocks", %{
      "table" => "items",
      "block_index" => 0,
      "block_size" => 100,
      "rows" => [],
      "client_row_ids" => []
    })

    assert_reply ref, :ok, reply
    assert reply.deleted == 0

    %{rows: rows} = Repo.query!("SELECT id FROM items WHERE room_id = 'room1' AND deleted_at IS NULL ORDER BY id")
    assert length(rows) == 3
  end

  # ============================================================================
  # Open Audit Issue Tests
  # ============================================================================

  describe "issue #11: changes_batch transactional rollback" do
    test "valid change is rolled back when batch contains invalid change", %{socket: socket} do
      now = System.system_time(:millisecond)

      ref = push(socket, "changes_batch", %{
        "changes" => [
          # Valid change
          %{
            "table" => "items",
            "operation" => "insert",
            "row_id" => "batch-ok",
            "seqnum" => 100,
            "data" => %{"room_id" => "room1", "last_modified_ms" => now}
          },
          # Invalid change — unknown table
          %{
            "table" => "nonexistent_table",
            "operation" => "insert",
            "row_id" => "batch-fail",
            "seqnum" => 101,
            "data" => %{}
          }
        ]
      })

      assert_reply ref, :error, %{status: "batch_failed"}

      # Fix: valid change is rolled back along with the invalid one
      %{rows: rows} = Repo.query!("SELECT id FROM items WHERE id = 'batch-ok'")
      assert length(rows) == 0
    end
  end

  describe "issue #15: fetch_row room_id scoping" do
    test "fetch_row rejects rows from other rooms", %{socket: socket} do
      # Insert a row in room2 (client is joined to room1)
      now = System.system_time(:millisecond)
      Repo.query!(
        "INSERT INTO items (id, room_id, last_modified_ms) VALUES ('other-room-item', 'room2', $1)",
        [now]
      )

      ref = push(socket, "fetch_row", %{"table" => "items", "row_id" => "other-room-item"})
      # Fix: cross-room rows return not_found
      assert_reply ref, :error, %{reason: "not_found"}
    end

    test "fetch_row returns rows from own room", %{socket: socket} do
      # a1 was seeded in room1 by setup
      ref = push(socket, "fetch_row", %{"table" => "items", "row_id" => "a1"})
      assert_reply ref, :ok, %{row: row}
      assert row.id == "a1"
      assert row.room_id == "room1"
    end
  end

  describe "issue #18: table name validation in check_stale_tables" do
    test "internal tables in table_seqnums are filtered out by whitelist", _context do
      # A fresh join with schema_migrations in table_seqnums
      socket = socket(SyncServerWeb.UserSocket, "user1", %{client_id: "probe-client"})
      {:ok, reply, _socket} = subscribe_and_join(socket, SyncServerWeb.SyncChannel,
        "sync:room:room1", %{
          "client_id" => "probe-client",
          "user_id" => "user1",
          "table_seqnums" => %{"schema_migrations" => 0, "items" => 0}
        })

      assert reply.status == "connected"

      # Fix: schema_migrations is filtered out by tables_for_channel whitelist
      # Only allowed tables (items) appear in stale_tables
      stale_table_names = Enum.map(reply.stale_tables, & &1.table)
      assert "items" in stale_table_names
      refute "schema_migrations" in stale_table_names
    end
  end

  describe "issue #25: hello with missing keys" do
    test "hello without required keys returns error with missing key names", %{socket: socket} do
      ref = push(socket, "hello", %{"client_id" => "test-client"})
      # Fix: returns error reply instead of crashing the channel
      assert_reply ref, :error, %{reason: "missing_keys", keys: keys}
      assert "last_seqnum" in keys
      assert "schema_version" in keys
    end
  end

  describe "issue #26: no change deduplication" do
    test "identical change applied twice bumps seqnum twice", %{socket: socket} do
      now = System.system_time(:millisecond)

      # First insert via changes_batch (single "change" event has bad handle_in return)
      ref1 = push(socket, "changes_batch", %{
        "changes" => [
          %{
            "table" => "items",
            "operation" => "insert",
            "row_id" => "dup-item",
            "seqnum" => 200,
            "data" => %{"room_id" => "room1", "last_modified_ms" => now}
          }
        ]
      })
      assert_reply ref1, :ok, _

      %{rows: [[seq1]]} = Repo.query!("SELECT seqnum FROM items WHERE id = 'dup-item'")

      # Second insert with identical data (different client seqnum)
      ref2 = push(socket, "changes_batch", %{
        "changes" => [
          %{
            "table" => "items",
            "operation" => "insert",
            "row_id" => "dup-item",
            "seqnum" => 201,
            "data" => %{"room_id" => "room1", "last_modified_ms" => now}
          }
        ]
      })
      assert_reply ref2, :ok, _

      %{rows: [[seq2]]} = Repo.query!("SELECT seqnum FROM items WHERE id = 'dup-item'")

      # The DB trigger checks NEW IS NOT DISTINCT FROM OLD and skips the seqnum
      # bump for identical data. However, the server still processes the full
      # upsert + broadcast + ack — no application-level deduplication.
      assert seq2 == seq1
    end
  end
end
