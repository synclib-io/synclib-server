defmodule SyncServer.Repo.Migrations.CreateTestTables do
  use Ecto.Migration

  def change do
    create table(:items, primary_key: false) do
      add :id, :string, primary_key: true
      add :document, :map
      add :room_id, :string
      add :last_modified_ms, :bigint
      add :seqnum, :bigint
      add :deleted_at, :utc_datetime
    end

    create index(:items, [:room_id])
    create index(:items, [:seqnum])
  end
end
