defmodule SyncServer.Repo.Migrations.CreateMmoTables do
  use Ecto.Migration

  def change do
    # Users
    create table(:users, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string
      add :email, :string
      add :document, :map
      add :online, :boolean, default: false
      add :last_modified_ms, :bigint
      add :seqnum, :bigint
      add :deleted_at, :utc_datetime
    end

    create index(:users, [:email])

    # Tasks
    create table(:tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string
      add :title, :string
      add :description, :text
      add :status, :string, default: "pending"
      add :document, :map
      add :last_modified_ms, :bigint
      add :seqnum, :bigint
      add :deleted_at, :utc_datetime
    end

    create index(:tasks, [:user_id])
    create index(:tasks, [:status])

    # Guild chat
    create table(:guild_chat, primary_key: false) do
      add :id, :string, primary_key: true
      add :guild_id, :string
      add :user_id, :string
      add :message, :text
      add :document, :map
      add :last_modified_ms, :bigint
      add :seqnum, :bigint
      add :deleted_at, :utc_datetime
    end

    create index(:guild_chat, [:guild_id])

    # Player positions
    create table(:player_positions, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string
      add :zone_id, :string
      add :x, :float, default: 0.0
      add :y, :float, default: 0.0
      add :z, :float, default: 0.0
      add :document, :map
      add :last_modified_ms, :bigint
      add :seqnum, :bigint
      add :deleted_at, :utc_datetime
    end

    create index(:player_positions, [:zone_id])
    create index(:player_positions, [:user_id])

    # World events
    create table(:world_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :event_type, :string
      add :title, :string
      add :description, :text
      add :document, :map
      add :last_modified_ms, :bigint
      add :seqnum, :bigint
      add :deleted_at, :utc_datetime
    end

    create index(:world_events, [:event_type])
  end
end
