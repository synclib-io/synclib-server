defmodule MMO.SnapshotQueries do
  @moduledoc """
  MMO snapshot queries — defines what data each channel type receives.

  Each function returns an Ecto query scoped to the channel's context.
  """

  @behaviour SyncServer.SnapshotQueries

  import Ecto.Query
  alias MMO.Schema.{User, Task, GuildChat, PlayerPosition, WorldEvent}
  require Logger

  @impl true
  def build_query("tasks", %{channel_type: :user, user_id: user_id} = assigns) do
    query = from(t in Task, where: t.user_id == ^user_id)
    maybe_filter_seqnum(query, assigns)
  end

  def build_query("users", %{channel_type: :user, user_id: user_id} = assigns) do
    query = from(u in User, where: u.id == ^user_id)
    maybe_filter_seqnum(query, assigns)
  end

  def build_query("guild_chat", %{channel_type: :guild, guild_id: guild_id} = assigns) do
    query = from(gc in GuildChat, where: gc.guild_id == ^guild_id)
    maybe_filter_seqnum(query, assigns)
  end

  def build_query("player_positions", %{channel_type: :zone, zone_id: zone_id} = assigns) do
    query = from(pp in PlayerPosition, where: pp.zone_id == ^zone_id)
    maybe_filter_seqnum(query, assigns)
  end

  def build_query("world_events", %{channel_type: :world} = assigns) do
    query = from(we in WorldEvent)
    maybe_filter_seqnum(query, assigns)
  end

  # Fallback for unknown table/channel combinations
  def build_query(table, assigns) do
    Logger.warning("No query builder for table: #{table}, channel_type: #{inspect(assigns[:channel_type])}")
    from(u in User, where: false)
  end

  # Apply seqnum filter for incremental sync
  defp maybe_filter_seqnum(query, %{since_seqnum: since_seqnum}) when is_integer(since_seqnum) and since_seqnum > 0 do
    from(q in query, where: q.seqnum > ^since_seqnum)
  end
  defp maybe_filter_seqnum(query, _assigns), do: query
end
