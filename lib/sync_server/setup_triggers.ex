defmodule SyncServer.SetupTriggers do
  @moduledoc """
  Attaches seqnum and row_hash triggers to all synced tables.

  Synced tables are auto-discovered (tables with both `id` and `deleted_at` columns).
  Safe to call repeatedly — drops and recreates triggers idempotently.

  Core infrastructure (global_seqnum_seq, update_seqnum_on_change function,
  pg_synclib_hash extension, row_hash columns) is created by the
  `SetupSyncInfrastructure` migration. This module only attaches triggers to tables.
  """

  require Logger

  def run do
    repo = SyncServer.Repo
    hash_columns = Application.get_env(:sync_server, :hash_columns, [])
    setup_row_hash = Application.get_env(:sync_server, :setup_row_hash_triggers, true)

    # Preflight: ensure core infrastructure exists (created by setup_sync_infrastructure migration)
    case repo.query("SELECT 1 FROM pg_proc WHERE proname = 'update_seqnum_on_change'") do
      {:ok, %{rows: [[1]]}} -> :ok
      _ ->
        Logger.error("[SetupTriggers] update_seqnum_on_change() function not found. Run migrations first: mix ecto.migrate")
        raise "SetupTriggers requires setup_sync_infrastructure migration. Run: mix ecto.migrate"
    end

    # Discover synced tables (have both 'id' and 'deleted_at')
    %{rows: tables} =
      repo.query!("""
        SELECT t.table_name
        FROM information_schema.columns t
        WHERE t.table_schema = 'public' AND t.column_name = 'id'
        AND EXISTS (
          SELECT 1 FROM information_schema.columns c
          WHERE c.table_schema = 'public'
            AND c.table_name = t.table_name
            AND c.column_name = 'deleted_at'
        )
        ORDER BY t.table_name
      """)

    for [table_name] <- tables do
      # Seqnum trigger (BEFORE INSERT OR UPDATE)
      repo.query!("DROP TRIGGER IF EXISTS #{table_name}_seqnum_trigger ON \"#{table_name}\"")

      repo.query!("""
        CREATE TRIGGER #{table_name}_seqnum_trigger
        BEFORE INSERT OR UPDATE ON "#{table_name}"
        FOR EACH ROW
        EXECUTE FUNCTION update_seqnum_on_change()
      """)

      # Row hash trigger (requires pg_synclib_hash extension)
      if setup_row_hash and extension_available?(repo) do
        # Ensure row_hash column exists (tables created after infrastructure migration may lack it)
        ensure_row_hash_column(repo, table_name)

        repo.query!("DROP TRIGGER IF EXISTS zzz_synclib_row_hash ON \"#{table_name}\"")

        if hash_columns != [] do
          args_str = hash_columns |> Enum.map(&"'#{&1}'") |> Enum.join(", ")

          repo.query!("""
            CREATE TRIGGER zzz_synclib_row_hash
            BEFORE INSERT OR UPDATE ON "#{table_name}"
            FOR EACH ROW
            EXECUTE FUNCTION synclib_compute_row_hash(#{args_str})
          """)
        else
          repo.query!("""
            CREATE TRIGGER zzz_synclib_row_hash
            BEFORE INSERT OR UPDATE ON "#{table_name}"
            FOR EACH ROW
            EXECUTE FUNCTION synclib_compute_row_hash()
          """)
        end

        # Backfill: touch rows with NULL/empty row_hash to trigger hash computation.
        # Uses "SET id = id" which is a no-op for the seqnum trigger (NEW IS NOT DISTINCT FROM OLD)
        # but fires the row_hash trigger to compute the hash.
        backfill_result = repo.query!("UPDATE \"#{table_name}\" SET id = id WHERE row_hash IS NULL OR row_hash = ''")
        if backfill_result.num_rows > 0 do
          Logger.info("[SetupTriggers] #{table_name}: backfilled row_hash for #{backfill_result.num_rows} rows")
        end

        Logger.info("[SetupTriggers] #{table_name}: seqnum + row_hash triggers ready")
      else
        Logger.info("[SetupTriggers] #{table_name}: seqnum trigger ready (row_hash skipped)")
      end
    end

    Logger.info("[SetupTriggers] Done — #{length(tables)} tables configured")
    :ok
  end

  # Ensure row_hash column exists on a table (tables created after infrastructure migration may lack it)
  defp ensure_row_hash_column(repo, table_name) do
    case repo.query(
      "SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = 'row_hash'",
      [table_name]
    ) do
      {:ok, %{rows: [[1]]}} -> :ok
      _ ->
        repo.query!("ALTER TABLE \"#{table_name}\" ADD COLUMN row_hash TEXT")
        Logger.info("[SetupTriggers] Added missing row_hash column to #{table_name}")
    end
  end

  # Check if pg_synclib_hash extension is available
  defp extension_available?(repo) do
    case repo.query("SELECT 1 FROM pg_extension WHERE extname = 'pg_synclib_hash'") do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
