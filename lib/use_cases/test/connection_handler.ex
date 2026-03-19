defmodule Test.ConnectionHandler do
  @behaviour SyncServer.ConnectionHandler

  require Logger

  @impl true
  def handle_connect(socket) do
    user_id = socket.assigns[:user_id]
    channel_type = socket.assigns[:channel_type]
    Logger.info("[Test] User #{user_id || "unknown"} connected to #{channel_type} channel")
    :ok
  end

  @impl true
  def handle_disconnect(reason, socket) do
    user_id = socket.assigns[:user_id]
    Logger.info("[Test] User #{user_id || "unknown"} disconnected: #{inspect(reason)}")
    :ok
  end
end
