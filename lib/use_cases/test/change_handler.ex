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
    Map.get(@schema_map, table, Item)
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
