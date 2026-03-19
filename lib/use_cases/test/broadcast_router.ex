defmodule Test.BroadcastRouter do
  @behaviour SyncServer.BroadcastRouter

  @impl true
  def determine_topic("items", data, socket) do
    case data["room_id"] do
      nil -> socket.topic
      room_id -> "sync:room:#{room_id}"
    end
  end

  def determine_topic(_table, _data, socket) do
    socket.topic
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
