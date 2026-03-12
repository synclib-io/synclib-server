defmodule MMO.ChangeHandler do
  @moduledoc """
  MMO change handler — applies client changes to the database.

  Handles insert, update, and delete operations for all MMO tables.
  """

  @behaviour SyncServer.ChangeHandler

  alias SyncServer.Repo
  alias MMO.Schema.{User, Task, GuildChat, PlayerPosition, WorldEvent}
  require Logger

  @schema_map %{
    "users" => User,
    "tasks" => Task,
    "guild_chat" => GuildChat,
    "player_positions" => PlayerPosition,
    "world_events" => WorldEvent
  }

  @impl true
  def apply_change(table, operation, row_id, data, assigns) do
    schema = Map.get(@schema_map, table)

    if schema do
      do_apply_change(schema, table, operation, row_id, data, assigns)
    else
      {:error, "unknown table: #{table}"}
    end
  end

  @impl true
  def get_schema_for_table(table) do
    Map.get(@schema_map, table, User)
  end

  # Insert
  defp do_apply_change(schema, _table, "insert", row_id, data, _assigns) do
    data = data
      |> Map.put("id", row_id)
      |> ensure_timestamps()

    changeset = schema.changeset(struct(schema), data)

    case Repo.insert(changeset, on_conflict: :replace_all, conflict_target: :id) do
      {:ok, record} -> {:ok, record}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Update
  defp do_apply_change(schema, _table, "update", row_id, data, _assigns) do
    case Repo.get(schema, row_id) do
      nil ->
        # Upsert: if row doesn't exist, insert it
        data = data
          |> Map.put("id", row_id)
          |> ensure_timestamps()

        changeset = schema.changeset(struct(schema), data)
        Repo.insert(changeset, on_conflict: :replace_all, conflict_target: :id)

      record ->
        changeset = schema.changeset(record, data)
        Repo.update(changeset)
    end
  end

  # Delete (soft delete)
  defp do_apply_change(schema, _table, "delete", row_id, _data, _assigns) do
    case Repo.get(schema, row_id) do
      nil ->
        {:ok, nil}

      record ->
        changeset = Ecto.Changeset.change(record, deleted_at: DateTime.utc_now())
        Repo.update(changeset)
    end
  end

  defp do_apply_change(_schema, _table, operation, _row_id, _data, _assigns) do
    {:error, "unknown operation: #{operation}"}
  end

  defp ensure_timestamps(data) do
    now = System.system_time(:millisecond)
    data
    |> Map.put_new("last_modified_ms", now)
  end
end
