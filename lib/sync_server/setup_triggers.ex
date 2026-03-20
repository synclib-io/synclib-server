defmodule SyncServer.SetupTriggers do
  @moduledoc """
  Sets up seqnum and row_hash triggers on all synced tables.

  Synced tables are auto-discovered (tables with both `id` and `deleted_at` columns).
  Safe to call repeatedly — drops and recreates triggers idempotently.

  Called at application startup so triggers are always current.

  ## pg_synclib_hash extension

  The row_hash trigger requires the `pg_synclib_hash` Postgres extension to be installed.
  If not installed, the seqnum trigger will still work but merkle verification will fall
  back to WASM-based computation (slower but functional).

  Set `config :sync_server, setup_row_hash_triggers: false` to skip row_hash triggers
  entirely if the extension is not available.
  """

  require Logger

  def run do
    repo = SyncServer.Repo
    hash_columns = Application.get_env(:sync_server, :hash_columns, [])
    setup_row_hash = Application.get_env(:sync_server, :setup_row_hash_triggers, true)

    # Ensure pg_synclib_hash extension (skip if not available)
    if setup_row_hash do
      try do
        repo.query!("CREATE EXTENSION IF NOT EXISTS pg_synclib_hash")
      rescue
        e ->
          Logger.warning("[SetupTriggers] pg_synclib_hash extension not available: #{Exception.message(e)}")
          Logger.warning("[SetupTriggers] Row hash triggers will be skipped. Merkle verification will use WASM fallback.")
      end
    end

    # Ensure global seqnum sequence and trigger function
    repo.query!("CREATE SEQUENCE IF NOT EXISTS global_seqnum_seq")

    repo.query!("""
      CREATE OR REPLACE FUNCTION update_seqnum_on_change()
      RETURNS TRIGGER AS $$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          NEW.seqnum = nextval('global_seqnum_seq');
        ELSIF TG_OP = 'UPDATE' THEN
          NEW.seqnum = OLD.seqnum;
          IF NEW IS NOT DISTINCT FROM OLD THEN
            RETURN NEW;
          ELSE
            NEW.seqnum = nextval('global_seqnum_seq');
          END IF;
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    """)

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

        Logger.info("[SetupTriggers] #{table_name}: seqnum + row_hash triggers ready")
      else
        Logger.info("[SetupTriggers] #{table_name}: seqnum trigger ready (row_hash skipped)")
      end
    end

    Logger.info("[SetupTriggers] Done — #{length(tables)} tables configured")
    :ok
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
