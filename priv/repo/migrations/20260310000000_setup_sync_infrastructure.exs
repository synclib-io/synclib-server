defmodule SyncServer.Repo.Migrations.SetupSyncInfrastructure do
  use Ecto.Migration

  @moduledoc """
  Core sync infrastructure: global seqnum sequence, trigger functions, and extension.

  This migration creates the foundational pieces that all synced tables depend on.
  Per-table trigger attachment is handled by SetupTriggers at application startup
  (since it depends on dynamic table discovery).

  Safe to run repeatedly — all statements use IF NOT EXISTS / CREATE OR REPLACE.
  """

  def up do
    # 1. Global seqnum sequence
    execute "CREATE SEQUENCE IF NOT EXISTS global_seqnum_seq"

    # 2. Seqnum trigger function (smart: skips no-op updates)
    execute """
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
    """

    # 3. pg_synclib_hash extension (for row_hash trigger)
    #    Fails gracefully if extension not compiled/installed
    execute """
    DO $$
    BEGIN
      CREATE EXTENSION IF NOT EXISTS pg_synclib_hash;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pg_synclib_hash extension not available: %. Row hash triggers will be skipped.', SQLERRM;
    END $$;
    """

    # Per-table setup (row_hash columns, trigger attachment) is handled by
    # SetupTriggers at application startup via dynamic table discovery.
  end

  def down do
    execute "DROP FUNCTION IF EXISTS update_seqnum_on_change() CASCADE"
    execute "DROP SEQUENCE IF EXISTS global_seqnum_seq CASCADE"
  end
end
