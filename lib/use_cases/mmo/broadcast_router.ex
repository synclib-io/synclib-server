defmodule MMO.BroadcastRouter do
  @moduledoc """
  MMO-specific logic for determining which Phoenix channel topic to broadcast changes to.

  For MMO games, broadcasts are typically scoped to zones/areas for performance.
  """

  @behaviour SyncServer.BroadcastRouter

  @impl true
  def determine_topic("users", _data, socket) do
    socket.topic
  end

  def determine_topic("tasks", _data, socket) do
    socket.topic
  end

  def determine_topic("player_positions", data, _socket) do
    zone_id = data["zone_id"]
    "sync:zone:#{zone_id}"
  end

  def determine_topic("guild_chat", data, _socket) do
    guild_id = data["guild_id"]
    "sync:guild:#{guild_id}"
  end

  def determine_topic("party_members", data, _socket) do
    party_id = data["party_id"]
    "sync:party:#{party_id}"
  end

  def determine_topic("world_events", _data, _socket) do
    "sync:world"
  end

  def determine_topic(_table, _data, _socket) do
    "sync:world"
  end

  @impl true
  def broadcast_change(socket, table, operation, row_id, data) do
    topic = determine_topic(table, data, socket)

    change_message = %{
      "table" => table,
      "operation" => operation,
      "row_id" => row_id,
      "data" => data,
      "timestamp" => System.system_time(:millisecond),
      "source" => "client"
    }

    SyncServerWeb.Endpoint.broadcast_from(socket.channel_pid, topic, "change", change_message)
    :ok
  end
end
