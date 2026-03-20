defmodule SyncServer.ServerAuthoritativeHashTest do
  @moduledoc """
  Integration tests for server-authoritative row_hash.

  Verifies that:
  - pg_synclib_hash trigger populates row_hash on INSERT/UPDATE
  - SetupTriggers.run() backfills row_hash for NULL/empty rows
  - No NULL row_hash values exist after trigger setup
  - Sentinel values ('') are handled correctly in merkle computation
  - COALESCE-based merkle queries include all rows (no pagination skew)

  Tests are skipped if pg_synclib_hash extension is not installed.
  """

  use SyncServer.DataCase

  alias SyncServer.Merkle

  defp extension_available? do
    case Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'pg_synclib_hash'") do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ============================================================================
  # row_hash trigger tests
  # ============================================================================

  describe "row_hash trigger" do
    test "INSERT populates row_hash via pg_synclib_hash trigger" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      Repo.query!("INSERT INTO items (id, room_id, last_modified_ms) VALUES ('h1', 'r1', 1000)")
      %{rows: [[row_hash]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'h1'")

      assert is_binary(row_hash)
      assert String.length(row_hash) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, row_hash)
    end

    test "UPDATE recomputes row_hash" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      Repo.query!("INSERT INTO items (id, room_id, last_modified_ms) VALUES ('h2', 'r1', 1000)")
      %{rows: [[hash1]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'h2'")

      Repo.query!("UPDATE items SET last_modified_ms = 2000 WHERE id = 'h2'")
      %{rows: [[hash2]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'h2'")

      assert hash1 != hash2
      assert String.length(hash2) == 64
    end

    test "no-op UPDATE preserves row_hash" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      Repo.query!("INSERT INTO items (id, room_id, last_modified_ms) VALUES ('h3', 'r1', 1000)")
      %{rows: [[hash1]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'h3'")

      Repo.query!("UPDATE items SET room_id = 'r1', last_modified_ms = 1000 WHERE id = 'h3'")
      %{rows: [[hash2]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'h3'")

      assert hash1 == hash2
    end
  end

  # ============================================================================
  # Backfill / no NULL tests
  # ============================================================================

  describe "backfill and NULL elimination" do
    test "no NULL row_hash values after SetupTriggers.run()" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      # Insert rows (triggers are already installed by DataCase setup)
      for id <- ["bf1", "bf2", "bf3"] do
        Repo.query!(
          "INSERT INTO items (id, room_id, last_modified_ms) VALUES ($1, 'r1', 1000)",
          [id]
        )
      end

      %{rows: [[null_count]]} =
        Repo.query!("SELECT COUNT(*) FROM items WHERE row_hash IS NULL")

      assert null_count == 0
    end

    test "backfill repairs rows with NULL row_hash" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      # Insert a row (trigger gives it a hash)
      Repo.query!("INSERT INTO items (id, room_id, last_modified_ms) VALUES ('bfn1', 'r1', 1000)")
      %{rows: [[original_hash]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'bfn1'")
      assert is_binary(original_hash) and String.length(original_hash) == 64

      # Drop the row_hash trigger, then set NULL to simulate pre-upgrade state
      Repo.query!("DROP TRIGGER IF EXISTS zzz_synclib_row_hash ON items")
      Repo.query!("UPDATE items SET row_hash = NULL WHERE id = 'bfn1'")
      %{rows: [[nil]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'bfn1'")

      # Re-run triggers (reinstalls trigger + backfill)
      SyncServer.SetupTriggers.run()

      %{rows: [[hash]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'bfn1'")
      assert is_binary(hash)
      assert String.length(hash) == 64
    end

    test "backfill repairs rows with empty sentinel row_hash" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      Repo.query!("INSERT INTO items (id, room_id, last_modified_ms) VALUES ('bfe1', 'r1', 1000)")

      # Drop trigger, set to sentinel
      Repo.query!("DROP TRIGGER IF EXISTS zzz_synclib_row_hash ON items")
      Repo.query!("UPDATE items SET row_hash = '' WHERE id = 'bfe1'")
      %{rows: [[hash_before]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'bfe1'")
      assert hash_before == ""

      # Re-run triggers (backfill targets NULL OR '')
      SyncServer.SetupTriggers.run()

      %{rows: [[hash_after]]} = Repo.query!("SELECT row_hash FROM items WHERE id = 'bfe1'")
      assert is_binary(hash_after)
      assert String.length(hash_after) == 64
      assert hash_after != ""
    end
  end

  # ============================================================================
  # Merkle with sentinel values
  # ============================================================================

  describe "merkle computation with sentinel values" do
    test "COALESCE query includes all rows even when some have empty row_hash" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      # Insert 5 rows — all get real hashes from trigger
      for i <- 1..5 do
        Repo.query!(
          "INSERT INTO items (id, room_id, last_modified_ms) VALUES ($1, 'merkle-room', $2)",
          ["m#{String.pad_leading(to_string(i), 2, "0")}", 1000 + i]
        )
      end

      # Forcibly set 2 rows to sentinel '' (must drop trigger first to prevent recompute)
      Repo.query!("DROP TRIGGER IF EXISTS zzz_synclib_row_hash ON items")
      Repo.query!("UPDATE items SET row_hash = '' WHERE id IN ('m02', 'm04')")

      # Merkle should still see all 5 rows (COALESCE prevents exclusion)
      assigns = %{channel_type: :room, room_id: "merkle-room"}
      result = Merkle.compute_root("items", assigns, 100)

      assert result.row_count == 5
      assert result.block_count == 1
      assert is_binary(result.root_hash)
      assert String.length(result.root_hash) == 64
    end

    test "sentinel values produce different block hash than real hashes" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      # Insert 3 rows with real hashes
      for i <- 1..3 do
        Repo.query!(
          "INSERT INTO items (id, room_id, last_modified_ms) VALUES ($1, 'sentinel-room', $2)",
          ["s#{String.pad_leading(to_string(i), 2, "0")}", 1000 + i]
        )
      end

      assigns = %{channel_type: :room, room_id: "sentinel-room"}
      root_with_hashes = Merkle.compute_root("items", assigns, 100)

      # Drop trigger, corrupt one hash to sentinel
      Repo.query!("DROP TRIGGER IF EXISTS zzz_synclib_row_hash ON items")
      Repo.query!("UPDATE items SET row_hash = '' WHERE id = 's02'")

      root_with_sentinel = Merkle.compute_root("items", assigns, 100)

      # Same row count, but different root hash (sentinel differs from real hash)
      assert root_with_hashes.row_count == root_with_sentinel.row_count
      assert root_with_hashes.root_hash != root_with_sentinel.root_hash
    end

    test "block boundary pagination is stable with sentinel values interspersed" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      # Insert 10 rows — use block_size=3 so we get multiple blocks
      for i <- 1..10 do
        Repo.query!(
          "INSERT INTO items (id, room_id, last_modified_ms) VALUES ($1, 'pag-room', $2)",
          ["p#{String.pad_leading(to_string(i), 2, "0")}", 1000 + i]
        )
      end

      assigns = %{channel_type: :room, room_id: "pag-room"}
      block_size = 3

      # Get block hashes and row IDs with all real hashes
      hashes_before = Merkle.compute_block_hashes("items", assigns, block_size)
      row_ids_block0 = Merkle.get_block_row_ids("items", 0, assigns, block_size)
      row_ids_block1 = Merkle.get_block_row_ids("items", 1, assigns, block_size)

      assert length(hashes_before) == 4  # ceil(10/3) = 4 blocks

      # Drop trigger, set sentinel values on rows in different blocks
      Repo.query!("DROP TRIGGER IF EXISTS zzz_synclib_row_hash ON items")
      Repo.query!("UPDATE items SET row_hash = '' WHERE id IN ('p02', 'p05', 'p09')")

      # Block boundaries should NOT shift — same row IDs in same blocks
      row_ids_block0_after = Merkle.get_block_row_ids("items", 0, assigns, block_size)
      row_ids_block1_after = Merkle.get_block_row_ids("items", 1, assigns, block_size)

      assert row_ids_block0 == row_ids_block0_after
      assert row_ids_block1 == row_ids_block1_after

      # Block hashes change only for blocks containing sentinel rows
      hashes_after = Merkle.compute_block_hashes("items", assigns, block_size)
      assert length(hashes_after) == 4  # Still 4 blocks

      # Block 0 has p01,p02,p03 — p02 is sentinel → different hash
      assert Enum.at(hashes_before, 0) != Enum.at(hashes_after, 0)
      # Block 1 has p04,p05,p06 — p05 is sentinel → different hash
      assert Enum.at(hashes_before, 1) != Enum.at(hashes_after, 1)
      # Block 2 has p07,p08,p09 — p09 is sentinel → different hash
      assert Enum.at(hashes_before, 2) != Enum.at(hashes_after, 2)
      # Block 3 has p10 — no sentinel → same hash
      assert Enum.at(hashes_before, 3) == Enum.at(hashes_after, 3)
    end

    test "find_differing_blocks detects blocks with sentinel values" do
      unless extension_available?(), do: flunk("pg_synclib_hash extension not available — skipping")

      # Insert 6 rows, block_size=2 → 3 blocks
      for i <- 1..6 do
        Repo.query!(
          "INSERT INTO items (id, room_id, last_modified_ms) VALUES ($1, 'diff-room', $2)",
          ["d#{String.pad_leading(to_string(i), 2, "0")}", 1000 + i]
        )
      end

      assigns = %{channel_type: :room, room_id: "diff-room"}
      block_size = 2

      # Get server's block hashes (all real)
      server_hashes = Merkle.compute_block_hashes("items", assigns, block_size)
      assert length(server_hashes) == 3

      # Simulate client with sentinel in block 1 (d03, d04)
      Repo.query!("DROP TRIGGER IF EXISTS zzz_synclib_row_hash ON items")
      Repo.query!("UPDATE items SET row_hash = '' WHERE id = 'd03'")
      client_hashes = Merkle.compute_block_hashes("items", assigns, block_size)

      # Restore triggers
      SyncServer.SetupTriggers.run()

      # Now compare: client_hashes (with sentinel) vs server (all real)
      differing = Merkle.find_differing_blocks("items", client_hashes, assigns, block_size)

      # Only block 1 should differ
      assert differing == [1]
    end
  end
end
