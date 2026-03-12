defmodule SyncServer.ChangeHandler do
  @moduledoc """
  Behaviour for handling incoming data changes from clients.

  Implement this to define authorization and CRUD logic for each table.
  The sync channel delegates all write operations to this module.

  ## Example

      defmodule MyApp.ChangeHandler do
        @behaviour SyncServer.ChangeHandler

        @impl true
        def apply_change("tasks", "insert", row_id, data, assigns) do
          %MyApp.Task{}
          |> MyApp.Task.changeset(Map.put(data, "id", row_id))
          |> MyApp.Repo.insert()
        end

        def apply_change("tasks", "update", row_id, data, _assigns) do
          case MyApp.Repo.get(MyApp.Task, row_id) do
            nil -> {:error, "not_found"}
            task -> task |> MyApp.Task.changeset(data) |> MyApp.Repo.update()
          end
        end

        def apply_change("tasks", "delete", row_id, _data, _assigns) do
          case MyApp.Repo.get(MyApp.Task, row_id) do
            nil -> {:ok, nil}
            task -> task |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> MyApp.Repo.update()
          end
        end

        @impl true
        def get_schema_for_table("tasks"), do: MyApp.Task
        def get_schema_for_table("users"), do: MyApp.User
      end
  """

  @doc """
  Apply a change (insert, update, delete) to a table.

  ## Parameters
  - `table` - Table name
  - `operation` - "insert", "update", or "delete"
  - `row_id` - The row's ID
  - `data` - Row data (empty map for deletes)
  - `assigns` - Socket assigns for authorization checks

  ## Returns
  - `{:ok, record}` on success (record should have `:seqnum` for ack)
  - `{:error, reason}` on failure
  """
  @callback apply_change(
              table :: String.t(),
              operation :: String.t(),
              row_id :: String.t(),
              data :: map(),
              assigns :: map()
            ) :: {:ok, any()} | {:error, any()}

  @doc """
  Get the Ecto schema module for a table name.

  Used by the sync channel for fetch_row and stripped content refresh.
  """
  @callback get_schema_for_table(table :: String.t()) :: module() | {String.t(), module()}
end
