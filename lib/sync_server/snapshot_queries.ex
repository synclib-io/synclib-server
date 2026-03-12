defmodule SyncServer.SnapshotQueries do
  @moduledoc """
  Behaviour for building scoped Ecto queries per table and channel.

  Implement this to define what data each channel type can see.
  The sync system uses these queries for:
  - Initial snapshot streaming
  - Incremental sync (with seqnum filtering)
  - Merkle tree verification (same data scope)

  ## Example

      defmodule MyApp.SnapshotQueries do
        @behaviour SyncServer.SnapshotQueries
        import Ecto.Query

        @impl true
        def build_query("tasks", %{channel_type: :user, user_id: user_id}) do
          from(t in MyApp.Task, where: t.user_id == ^user_id)
        end

        def build_query(_table, _assigns) do
          # Return empty query for unknown combinations
          from(u in MyApp.User, where: false)
        end
      end
  """

  @doc """
  Build an Ecto query for a table, scoped to the channel's assigns.

  The query MUST return rows that have at minimum `id`, `seqnum`, and `deleted_at` fields.

  ## Parameters
  - `table` - Table name as a string (e.g., "tasks")
  - `assigns` - Socket assigns containing channel_type, user_id, guild_id, etc.
    May also include `:since_seqnum` for incremental sync filtering.

  ## Returns
  An `Ecto.Query` that selects the appropriate rows for this channel.
  """
  @callback build_query(table :: String.t(), assigns :: map()) :: Ecto.Query.t()
end
