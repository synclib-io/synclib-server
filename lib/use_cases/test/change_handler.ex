defmodule Test.ChangeHandler do
  @behaviour SyncServer.ChangeHandler

  alias SyncServer.Repo
  alias Test.Schema.Item
  require Logger

  @schema_map %{
    "items" => Item
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
    Map.get(@schema_map, table)
  end

  # Insert
  defp do_apply_change(schema, _table, "insert", row_id, data, _assigns) do
    data = data
      |> Map.put("id", row_id)
      |> ensure_timestamps()

    case Repo.get(schema, row_id) do
      nil ->
        changeset = schema.changeset(struct(schema), data)
        Repo.insert(changeset)

      existing ->
        incoming_ts = data["last_modified_ms"] || 0
        existing_ts = existing.last_modified_ms || 0

        if incoming_ts >= existing_ts do
          changeset = schema.changeset(existing, data)
          Repo.update(changeset)
        else
          {:ok, existing}
        end
    end
  end

  # Update
  defp do_apply_change(schema, _table, "update", row_id, data, _assigns) do
    case Repo.get(schema, row_id) do
      nil ->
        data = data
          |> Map.put("id", row_id)
          |> ensure_timestamps()

        changeset = schema.changeset(struct(schema), data)
        Repo.insert(changeset)

      record ->
        incoming_ts = data["last_modified_ms"] || 0
        existing_ts = record.last_modified_ms || 0

        if incoming_ts >= existing_ts do
          changeset = schema.changeset(record, data)
          Repo.update(changeset)
        else
          {:ok, record}
        end
    end
  end

  # Delete (soft delete)
  defp do_apply_change(schema, _table, "delete", row_id, _data, _assigns) do
    case Repo.get(schema, row_id) do
      nil ->
        {:ok, nil}

      record ->
        changeset = Ecto.Changeset.change(record, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
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
