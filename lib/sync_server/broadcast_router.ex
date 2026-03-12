defmodule SyncServer.BroadcastRouter do
  @moduledoc """
  Behaviour for routing database changes to the correct channel topics.

  When a client pushes a change, it needs to be broadcast to other clients
  who are subscribed to relevant channels. This behaviour defines how to
  determine which topic to broadcast to.

  ## Example

      defmodule MyApp.BroadcastRouter do
        @behaviour SyncServer.BroadcastRouter

        @impl true
        def determine_topic("users", _data, socket), do: socket.topic

        def determine_topic("player_positions", data, _socket) do
          "sync:zone:\#{data["zone_id"]}"
        end

        def determine_topic(_table, _data, _socket), do: "sync:world"

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
  """

  @doc """
  Determine which channel topic to broadcast a change to.
  """
  @callback determine_topic(table :: String.t(), data :: map(), socket :: Phoenix.Socket.t()) ::
              String.t()

  @doc """
  Broadcast a change to the appropriate topic(s).

  Should use `broadcast_from` to exclude the originating client.
  """
  @callback broadcast_change(
              socket :: Phoenix.Socket.t(),
              table :: String.t(),
              operation :: String.t(),
              row_id :: String.t(),
              data :: map()
            ) :: :ok
end
