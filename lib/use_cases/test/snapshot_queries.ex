defmodule Test.SnapshotQueries do
  @behaviour SyncServer.SnapshotQueries

  import Ecto.Query
  alias Test.Schema.Item
  require Logger

  @impl true
  def build_query("items", %{channel_type: :room, room_id: room_id} = assigns) do
    query = from(i in Item, where: i.room_id == ^room_id)
    maybe_filter_seqnum(query, assigns)
  end

  # Fallback for unknown table/channel combinations
  def build_query(table, assigns) do
    Logger.warning("[Test] No query builder for table: #{table}, channel_type: #{inspect(assigns[:channel_type])}")
    from(i in Item, where: false)
  end

  defp maybe_filter_seqnum(query, %{since_seqnum: since_seqnum}) when is_integer(since_seqnum) and since_seqnum > 0 do
    from(q in query, where: q.seqnum > ^since_seqnum)
  end
  defp maybe_filter_seqnum(query, _assigns), do: query
end
