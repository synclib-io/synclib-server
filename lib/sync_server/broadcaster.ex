defmodule SyncServer.Broadcaster do
  @moduledoc """
  Helper module for broadcasting messages to Phoenix channels.

  Provides convenient functions to broadcast to specific channel types:
  - User channels (private data)
  - World channel (global announcements)
  - Zone channels (location-based)
  - Guild channels (team-specific)
  - Party channels (small groups)
  """

  alias SyncServerWeb.Endpoint
  require Logger

  @doc """
  Broadcast a message to a specific user's channel.
  """
  def to_user(user_id, event, payload) do
    topic = "sync:user:#{user_id}"
    Endpoint.broadcast(topic, event, payload)
  end

  @doc """
  Broadcast a message to multiple users.
  """
  def to_users(user_ids, event, payload) when is_list(user_ids) do
    Enum.each(user_ids, fn user_id ->
      to_user(user_id, event, payload)
    end)
  end

  @doc """
  Broadcast a message to the world channel (all connected clients).
  """
  def to_world(event, payload) do
    Endpoint.broadcast("sync:world", event, payload)
  end

  @doc """
  Broadcast a message to a specific zone channel.
  """
  def to_zone(zone_id, event, payload) do
    topic = "sync:zone:#{zone_id}"
    Endpoint.broadcast(topic, event, payload)
  end

  @doc """
  Broadcast a message to multiple zones.
  """
  def to_zones(zone_ids, event, payload) when is_list(zone_ids) do
    Enum.each(zone_ids, fn zone_id ->
      to_zone(zone_id, event, payload)
    end)
  end

  @doc """
  Broadcast a message to a specific guild channel.
  """
  def to_guild(guild_id, event, payload) do
    topic = "sync:guild:#{guild_id}"
    Endpoint.broadcast(topic, event, payload)
  end

  @doc """
  Broadcast a message to a specific party channel.
  """
  def to_party(party_id, event, payload) do
    topic = "sync:party:#{party_id}"
    Endpoint.broadcast(topic, event, payload)
  end

  @doc """
  Broadcast a database change event with scoped routing.

  ## Options
  - `:scope` - Override auto-routing. Examples: `{:user, "user-123"}`, `{:zone, "forest_1"}`, `:world`

  ## Examples

      # Auto-scope based on table/data
      Broadcaster.broadcast_change("users", "update", "user-123", %{"id" => "user-123", "name" => "Alice"})

      # Manually specify scope
      Broadcaster.broadcast_change("tasks", "insert", "task-1", data, scope: {:user, "user-123"})
      Broadcaster.broadcast_change("announcement", "insert", "ann-1", data, scope: :world)
  """
  def broadcast_change(table, operation, row_id, data, opts \\ []) do
    scope = Keyword.get(opts, :scope, :auto)

    change = %{
      "table" => table,
      "operation" => operation,
      "row_id" => row_id,
      "data" => data,
      "timestamp" => System.system_time(:second),
      "source" => "server"
    }

    case scope do
      :auto ->
        auto_broadcast_change(table, data, change)

      {:user, user_id} ->
        to_user(user_id, "change", change)

      {:zone, zone_id} ->
        to_zone(zone_id, "change", change)

      {:guild, guild_id} ->
        to_guild(guild_id, "change", change)

      {:party, party_id} ->
        to_party(party_id, "change", change)

      :world ->
        to_world("change", change)
    end
  end

  defp auto_broadcast_change("users", data, change) do
    user_id = data["id"]
    to_user(user_id, "change", change)
  end

  defp auto_broadcast_change("tasks", data, change) do
    user_id = data["user_id"]
    to_user(user_id, "change", change)
  end

  defp auto_broadcast_change("player_positions", data, change) do
    zone_id = data["zone_id"]
    to_zone(zone_id, "change", change)
  end

  defp auto_broadcast_change("guild_chat", data, change) do
    guild_id = data["guild_id"]
    to_guild(guild_id, "change", change)
  end

  defp auto_broadcast_change("world_events", _data, change) do
    to_world("change", change)
  end

  defp auto_broadcast_change(_table, _data, change) do
    to_world("change", change)
  end

  @doc """
  Broadcast a custom event to a specific channel.
  """
  def custom(topic, event, payload) do
    Endpoint.broadcast(topic, event, payload)
  end

  @doc """
  Broadcast a schema update notification to all connected clients.
  """
  def broadcast_schema_update(new_version, migrations \\ nil) do
    payload = %{
      "new_version" => new_version,
      "migrations" => migrations,
      "timestamp" => System.system_time(:second)
    }

    to_world("schema_update", payload)
  end

end
